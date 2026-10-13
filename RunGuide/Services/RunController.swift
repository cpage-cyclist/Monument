import Foundation
import RunGuideCore

/// Glues GPS, the clock and the voice to the session engine.
@MainActor
final class RunController: ObservableObject {
    let engine: SessionEngine
    let tracker: LocationTracker
    private let announcer = Announcer()

    /// Bumped on every update so the screen refreshes.
    @Published private(set) var tick = 0
    @Published private(set) var paused = false
    @Published private(set) var finished = false

    private var timer: Timer?
    private var lastTick: Date?
    private var pendingDistance = 0.0
    private var started = false

    init(workout: Workout, options: EngineOptions, tracker: LocationTracker) {
        self.engine = SessionEngine(workout: workout, options: options)
        self.tracker = tracker
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
        tracker.beginCounting()

        lastTick = Date()
        handle(engine.start())

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
    }

    /// Feeds elapsed time and distance into the engine. Runs every second and
    /// on every GPS update, so it keeps going with the screen locked.
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
        handle(engine.advance(distance: metres, time: seconds))
        tick &+= 1
    }

    func togglePause() {
        guard !finished else { return }
        if paused {
            tracker.resumeCounting()
            lastTick = Date()
            paused = false
            announcer.speak("Resumed.")
        } else {
            step()
            paused = true
            tracker.pauseCounting()
            announcer.speak("Paused.")
        }
        tick &+= 1
    }

    func lap() {
        guard !finished else { return }
        step()
        handle(engine.manualLap())
        tick &+= 1
    }

    func end() {
        guard !finished else { return }
        step()
        handle(engine.finishEarly())
    }

    func cleanUp() {
        timer?.invalidate()
        timer = nil
        tracker.stop()
        tracker.onDistance = nil
        tracker.onUpdate = nil
    }

    private func handle(_ events: [EngineEvent]) {
        for event in events {
            switch event {
            case .speak(let text):
                announcer.speak(text)
            case .lap:
                break
            case .finished:
                finished = true
                cleanUp()
                tick &+= 1
            }
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
}
