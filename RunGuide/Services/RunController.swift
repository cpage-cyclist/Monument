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
    /// Fixed for the session.
    let sport: RecordSport
    /// Power meter and cadence sensor, for rides.
    let power: CyclingSensor?
    let cadenceSensor: CyclingSensor?
    private let store: RunStore
    private let client: IntervalsClient?
    private let strava: StravaAccount?
    private let announcer = Announcer()
    private var recorder: ActivityRecorder

    /// Efforts marked on the route, played when there's no planned session.
    let effortPlayer: RouteEffortPlayer?
    /// For turning % and zone targets on route efforts into watts.
    let ftp: Double?
    private let feedbackOn: Bool
    /// Mid-effort feedback for the block under way: a workout step or a route effort.
    private var feedback: EffortFeedback?

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
    init(workout: Workout, sport: RecordSport, options: EngineOptions, tracker: LocationTracker,
         heartRate: HeartRateMonitor, power: CyclingSensor? = nil, cadence: CyclingSensor? = nil,
         store: RunStore, client: IntervalsClient?,
         route: Route? = nil, loopRoute: Bool = false, strava: StravaAccount? = nil,
         efforts: [RouteEffort] = [], ftp: Double? = nil, effortFeedback: Bool = true) {
        var options = options
        options.sport = sport
        self.sport = sport
        let engine = SessionEngine(workout: workout, options: options)
        let guide = route.map { r in
            let g = RouteGuide(route: r, loop: loopRoute)
            g.headsUp = sport.routeHeadsUp
            g.nowDistance = sport.routeNow
            g.chainDistance = sport.routeChain
            return g
        }
        self.engine = engine
        self.guide = guide
        // A planned session has its own structure; the route's efforts play on a free recording.
        if let guide, engine.isFree, !efforts.isEmpty {
            effortPlayer = RouteEffortPlayer(efforts: efforts, guide: guide, sport: sport)
        } else {
            effortPlayer = nil
        }
        self.ftp = ftp
        self.feedbackOn = effortFeedback
        self.tracker = tracker
        self.heartRate = heartRate
        self.power = sport.usesPower && power?.isPaired == true ? power : nil
        self.cadenceSensor = sport.usesPower && cadence?.isPaired == true ? cadence : nil
        self.store = store
        self.client = client
        self.strava = strava
        if strava != nil { stravaUpload = .notStarted }
        self.recorder = ActivityRecorder(name: workout.name, start: Date(), sport: sport)
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
        power?.connect()
        cadenceSensor?.connect()

        let now = Date()
        recorder = ActivityRecorder(name: engine.workout.name, start: now, sport: sport)
        lastTick = now
        handle(engine.start(), at: now)
        startStepFeedback()

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
        // Feedback takes this second before the engine moves on, so a step's end is measured too.
        if let line = feedback?.add(seconds: seconds, metres: metres, watts: power?.currentWatts.map(Double.init)) {
            announcer.speak(line)
        }
        let stepBefore = engine.stepIndex
        let events = engine.advance(distance: metres, time: seconds)
        let stepChanged = engine.stepIndex != stepBefore && effortPlayer == nil
        if stepChanged, let line = feedback?.finish() { announcer.speak(line) }
        recordPoint(at: now)
        handle(events, at: now)
        if stepChanged { startStepFeedback() }
        updateEfforts(at: now)
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
            let fileURL = store.url(for: run), summary = summaryText, sportType = sport.stravaType
            let id = try await BackgroundTime.run("Strava upload") {
                try await strava.uploadActivity(fileURL: fileURL, name: run.name, description: summary,
                                                externalID: run.fileName, sportType: sportType)
            }
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
        power?.disconnect()
        cadenceSensor?.disconnect()
    }

    // MARK: - Internals

    /// Route guidance runs off raw GPS fixes; its cues cut in over interval cues.
    private func follow(_ location: CLLocation) {
        guard let guide, started, !finished else { return }
        let said = guide.update(lat: location.coordinate.latitude, lon: location.coordinate.longitude,
                                accuracy: location.horizontalAccuracy, time: location.timestamp)
        for text in said { announcer.speak(text, urgent: true) }
        if !said.isEmpty { tick &+= 1 }
        updateEfforts(at: Date())
    }

    // MARK: - Route efforts and feedback

    /// Plays the route's efforts: heads-ups and countdowns, a lap at each start and end, and
    /// feedback over each effort that has a power or pace target.
    private func updateEfforts(at now: Date) {
        guard let player = effortPlayer, !paused, !finished else { return }
        let events = player.update(time: engine.totalTime, speed: tracker.speed.flatMap { $0 >= 0 ? $0 : nil })
        for event in events {
            switch event {
            case .speak(let text, let urgent):
                announcer.speak(text, urgent: urgent)
            case .started(let effort):
                handle(engine.splitLap(label: "Easy", kind: .rest), at: now)
                feedback = nil
                if feedbackOn, let target = FeedbackTarget.forEffort(effort, ftp: ftp),
                   let length = feedbackLength(effort, player: player) {
                    feedback = EffortFeedback(target: target, length: length)
                }
            case .ended(let effort):
                if let line = feedback?.finish() { announcer.speak(line) }
                feedback = nil
                handle(engine.splitLap(label: effort.label, kind: .active), at: now)
            case .skipped:
                break
            }
        }
        if !events.isEmpty { tick &+= 1 }
    }

    /// What a route effort's checkpoints are fractions of: its own length, else the stretch to
    /// its EASY (or the next GO), else the rest of the route.
    private func feedbackLength(_ effort: RouteEffort, player: RouteEffortPlayer) -> FeedbackLength? {
        switch effort.length {
        case .time(let s): return .time(s)
        case .distance(let d): return .distance(d)
        case nil:
            if let stop = effort.stop { return .distance(stop - effort.start) }
            let rest = player.guide.route.length - effort.start
            return rest > 50 ? .distance(rest) : nil
        }
    }

    /// Feedback for the workout step now under way, if it's an effort with a power or pace target.
    private func startStepFeedback() {
        guard effortPlayer == nil else { return }
        feedback = nil
        guard feedbackOn, let step = engine.currentStep, let target = FeedbackTarget.forStep(step) else { return }
        switch step.end {
        case .time(let s): feedback = EffortFeedback(target: target, length: .time(s))
        case .distance(let d): feedback = EffortFeedback(target: target, length: .distance(d))
        case .open: break
        }
    }

    /// The route effort under way, for the screen.
    var activeEffort: RouteEffort? { effortPlayer?.active?.effort }

    /// Watts to aim for now: the route effort's, else the step's.
    var targetWatts: ClosedRange<Double>? {
        if let e = activeEffort { return e.watts(ftp: ftp) }
        return engine.currentStep?.watts
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
            heartRate: heartRate.currentBPM,
            power: power?.currentWatts,
            cadence: currentCadence
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
            let fileURL = store.url(for: run), summary = summaryText
            let id = try await BackgroundTime.run("Intervals upload") {
                try await client.uploadActivity(fileURL: fileURL, name: run.name, description: summary)
            }
            store.markUploaded(run, activityId: id)
            upload = .uploaded
        } catch {
            upload = .failed(error.localizedDescription)
        }
    }

    // MARK: - Screen helpers

    /// km/h, for rides.
    var currentSpeed: Double? {
        guard let speed = tracker.speed, speed >= 0 else { return nil }
        return speed * 3.6
    }

    /// Cadence from the power meter if it sends it, else the cadence sensor.
    var currentCadence: Int? { power?.currentCadence ?? cadenceSensor?.currentCadence }

    var hasPowerSensors: Bool { power != nil || cadenceSensor != nil }

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
