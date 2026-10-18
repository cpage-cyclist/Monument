import CoreLocation
import Foundation
import RunGuideCore

/// Glues GPS, heart rate, the clock and the voice to the session engine, and
/// records the run so it can be saved as a FIT file and uploaded.
@MainActor
final class RunController: ObservableObject {
    enum UploadState: Equatable {
        /// Run finished; waiting for the runner to save or discard it.
        case notStarted
        case uploading
        case uploaded
        case failed(String)
        case off
    }

    let engine: SessionEngine
    /// Turn-by-turn guidance when running a route.
    let guide: RouteGuide?
    let tracker: LocationTracker
    let heartRate: HeartRateMonitor
    private let store: RunStore
    private let client: IntervalsClient?
    private let strava: StravaAccount?
    private let announcer = Announcer()
    private var recorder: ActivityRecorder

    /// Bumped on every update so the screen refreshes.
    @Published private(set) var tick = 0
    @Published private(set) var paused = false
    @Published private(set) var finished = false
    @Published private(set) var savedRun: SavedRun?
    @Published private(set) var saveFailed = false
    @Published private(set) var upload: UploadState = .notStarted
    @Published private(set) var stravaUpload: UploadState = .off
    /// The runner has chosen to keep the run (Save) — nothing uploads before this.
    @Published private(set) var kept = false
    @Published private(set) var discarded = false

    private var timer: Timer?
    private var lastTick: Date?
    private var lastPoint: Date?
    private var pendingDistance = 0.0
    private var started = false

    /// `client` is nil when auto-upload is off or Intervals isn't set up.
    init(workout: Workout, options: EngineOptions, tracker: LocationTracker,
         heartRate: HeartRateMonitor, store: RunStore, client: IntervalsClient?,
         route: Route? = nil, loopRoute: Bool = false, strava: StravaAccount? = nil) {
        self.engine = SessionEngine(workout: workout, options: options)
        self.guide = route.map { RouteGuide(route: $0, loop: loopRoute) }
        self.tracker = tracker
        self.heartRate = heartRate
        self.store = store
        self.client = client
        self.strava = strava
        if strava != nil { stravaUpload = .notStarted }
        self.recorder = ActivityRecorder(name: workout.name, start: Date())
        if client == nil { upload = .off }
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true

        tracker.onDistance = { [weak self] metres in
            MainActor.assumeIsolated { self?.pendingDistance += metres }
        }
        tracker.onUpdate = { [weak self] in
            MainActor.assumeIsolated { self?.step() }
        }
        tracker.onFix = { [weak self] location in
            MainActor.assumeIsolated { self?.follow(location) }
        }
        tracker.beginCounting()
        heartRate.connect()

        let now = Date()
        recorder = ActivityRecorder(name: engine.workout.name, start: now)
        lastTick = now
        handle(engine.start(), at: now)

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
    }

    /// Feeds elapsed time and distance into the engine and records a point.
    /// Runs every second and on every GPS update, so it keeps going with the
    /// screen locked.
    func step() {
        guard started, !finished, let last = lastTick else { return }
        let now = Date()
        lastTick = now
        if paused {
            pendingDistance = 0
            return
        }
        let seconds = now.timeIntervalSince(last)
        let metres = pendingDistance
        pendingDistance = 0
        let events = engine.advance(distance: metres, time: seconds)
        recordPoint(at: now)
        handle(events, at: now)
        tick &+= 1
    }

    func togglePause() {
        guard !finished else { return }
        let now = Date()
        if paused {
            tracker.resumeCounting()
            recorder.resume(at: now)
            lastTick = now
            paused = false
            announcer.speak("Resumed.")
        } else {
            step()
            paused = true
            tracker.pauseCounting()
            recorder.pause(at: now)
            announcer.speak("Paused.")
        }
        tick &+= 1
    }

    func lap() {
        guard !finished else { return }
        step()
        handle(engine.manualLap(), at: Date())
        tick &+= 1
    }

    func end() {
        guard !finished else { return }
        step()
        handle(engine.finishEarly(), at: Date())
    }

    /// Keep the run and upload it if auto-upload is on.
    func keep() {
        guard finished, !kept, !discarded else { return }
        kept = true
        if let run = savedRun, client != nil {
            Task { await uploadRun(run) }
        }
        if let run = savedRun, strava != nil {
            Task { await uploadToStrava(run) }
        }
    }

    func retryStravaUpload() {
        guard let run = savedRun else { return }
        Task { await uploadToStrava(run) }
    }

    private func uploadToStrava(_ run: SavedRun) async {
        guard let strava else { return }
        stravaUpload = .uploading
        do {
            let id = try await strava.uploadActivity(fileURL: store.url(for: run), name: run.name,
                                                     description: summaryText, externalID: run.fileName)
            store.markUploadedToStrava(run, activityId: id)
            stravaUpload = .uploaded
        } catch {
            stravaUpload = .failed(error.localizedDescription)
        }
    }

    /// Throw the run away: deletes the FIT file and nothing is uploaded.
    func discard() {
        guard finished, !kept else { return }
        if let run = savedRun { store.delete(run) }
        savedRun = nil
        discarded = true
    }

    func retryUpload() {
        guard let run = savedRun else { return }
        Task { await uploadRun(run) }
    }

    func cleanUp() {
        timer?.invalidate()
        timer = nil
        tracker.stop()
        tracker.onDistance = nil
        tracker.onUpdate = nil
        tracker.onFix = nil
        heartRate.disconnect()
    }

    // MARK: - Internals

    /// Route guidance runs off raw GPS fixes; its cues cut in over interval cues.
    private func follow(_ location: CLLocation) {
        guard let guide, started, !finished else { return }
        let said = guide.update(lat: location.coordinate.latitude, lon: location.coordinate.longitude,
                                accuracy: location.horizontalAccuracy, time: location.timestamp)
        for text in said { announcer.speak(text, urgent: true) }
        if !said.isEmpty { tick &+= 1 }
    }

    private func recordPoint(at now: Date) {
        if let lastPoint, now.timeIntervalSince(lastPoint) < 0.9 { return }
        lastPoint = now
        let fix = tracker.latest.flatMap { abs($0.timestamp.timeIntervalSince(now)) < 3 ? $0 : nil }
        recorder.addPoint(TrackPoint(
            time: now,
            latitude: fix?.coordinate.latitude,
            longitude: fix?.coordinate.longitude,
            altitude: fix.flatMap { $0.verticalAccuracy >= 0 ? $0.altitude : nil },
            distance: engine.totalDistance,
            speed: fix.flatMap { $0.speed >= 0 ? $0.speed : nil },
            heartRate: heartRate.currentBPM
        ))
    }

    private func handle(_ events: [EngineEvent], at now: Date) {
        for event in events {
            switch event {
            case .speak(let text):
                announcer.speak(text)
            case .lap(let lap):
                recorder.closeLap(lap, at: now)
            case .finished:
                finish(at: now)
            }
        }
    }

    private func finish(at now: Date) {
        finished = true
        cleanUp()
        let recording = recorder.finish(at: now, totalDistance: engine.totalDistance,
                                        totalTimerTime: engine.totalTime)
        // Saved on the phone straight away so nothing is lost if the app closes,
        // but only uploaded once the runner taps Save.
        if let run = store.save(recording) {
            savedRun = run
        } else {
            saveFailed = true
        }
        tick &+= 1
    }

    private func uploadRun(_ run: SavedRun) async {
        guard let client else { return }
        upload = .uploading
        do {
            let id = try await client.uploadActivity(fileURL: store.url(for: run),
                                                     name: run.name,
                                                     description: summaryText)
            store.markUploaded(run, activityId: id)
            upload = .uploaded
        } catch {
            upload = .failed(error.localizedDescription)
        }
    }

    // MARK: - Screen helpers

    var currentPace: Double? {
        guard let speed = tracker.speed, speed > 0.5 else { return nil }
        return 1000 / speed
    }

    var summaryText: String {
        SessionSummary.text(workout: engine.workout, laps: engine.laps,
                            totalDistance: engine.totalDistance, totalTime: engine.totalTime)
    }

    var fileURL: URL? {
        savedRun.map { store.url(for: $0) }
    }
}
