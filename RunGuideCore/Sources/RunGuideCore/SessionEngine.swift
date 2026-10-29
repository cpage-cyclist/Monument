import Foundation

/// Why a lap ended.
public enum LapTrigger: Hashable {
    case distance, time, manual, sessionEnd
}

public struct Lap: Hashable {
    public let stepIndex: Int
    public let label: String
    public let distance: Double   // metres
    public let duration: Double   // seconds of timer time (excludes pauses)
    public let kind: StepKind
    public let trigger: LapTrigger

    public init(stepIndex: Int, label: String, distance: Double, duration: Double,
                kind: StepKind = .active, trigger: LapTrigger = .manual) {
        self.stepIndex = stepIndex
        self.label = label
        self.distance = distance
        self.duration = duration
        self.kind = kind
        self.trigger = trigger
    }

    /// Seconds per km, or nil if the lap is too short to say.
    public var pace: Double? {
        distance >= 20 ? duration / (distance / 1000) : nil
    }
}

public enum EngineEvent: Equatable {
    case speak(String)
    case lap(Lap)
    case finished
}

extension Workout {
    /// A run with no structure: one open step that lasts until you end it.
    public static func freeRun(name: String) -> Workout {
        Workout(name: name, steps: [Step(id: 0, label: "Run", end: .open, target: nil)])
    }
}

public struct EngineOptions: Equatable {
    /// Say the pace of each step when it finishes.
    public var lapPaceFeedback: Bool
    /// Say a split every km during long steps (≥ 2 km or ≥ 10 min).
    public var kmSplits: Bool
    /// Rides say speed instead of pace, and split every 5 km rather than every km.
    public var sport: RecordSport

    public init(lapPaceFeedback: Bool = true, kmSplits: Bool = true, sport: RecordSport = .run) {
        self.lapPaceFeedback = lapPaceFeedback
        self.kmSplits = kmSplits
        self.sport = sport
    }
}

/// The session state machine. Feed it distance and time as they happen; it
/// decides when each step ends (auto-lap), and what to say and when.
///
/// It has no idea about GPS, clocks or audio, which keeps it testable.
public final class SessionEngine {
    public let workout: Workout
    public var options: EngineOptions

    public private(set) var stepIndex = 0
    public private(set) var stepDistance = 0.0
    public private(set) var stepTime = 0.0
    public private(set) var totalDistance = 0.0
    public private(set) var totalTime = 0.0
    public private(set) var laps: [Lap] = []
    public private(set) var started = false
    public private(set) var finished = false

    private var firedCues = Set<Int>()
    private var splitsAnnounced = 0
    private var lastSplitTime = 0.0

    public init(workout: Workout, options: EngineOptions = EngineOptions()) {
        self.workout = workout
        self.options = options
    }

    // MARK: - State for the screen

    public var currentStep: Step? {
        guard !finished, stepIndex < workout.steps.count else { return nil }
        return workout.steps[stepIndex]
    }

    public var nextStep: Step? {
        guard !finished, stepIndex + 1 < workout.steps.count else { return nil }
        return workout.steps[stepIndex + 1]
    }

    /// Metres or seconds left in the current step; nil for open steps.
    public var remaining: Double? {
        guard let step = currentStep else { return nil }
        switch step.end {
        case .distance(let d): return max(0, d - stepDistance)
        case .time(let t): return max(0, t - stepTime)
        case .open: return nil
        }
    }

    public var stepProgress: Double {
        guard let step = currentStep else { return finished ? 1 : 0 }
        switch step.end {
        case .distance(let d): return d > 0 ? min(1, stepDistance / d) : 0
        case .time(let t): return t > 0 ? min(1, stepTime / t) : 0
        case .open: return 0
        }
    }

    // MARK: - Driving it

    public func start() -> [EngineEvent] {
        guard !started else { return [] }
        started = true
        guard let step = currentStep else {
            finished = true
            return [.speak("There are no steps in this session."), .finished]
        }
        // A free run (one open step, e.g. following a route with no session) just starts.
        if workout.steps.count == 1, case .open = step.end, step.target == nil {
            return [.speak("Starting \(workout.name).")]
        }
        return [.speak("Starting \(workout.name). " + Speech.intro(step))]
    }

    /// Add distance (metres) and time (seconds) covered since the last call.
    public func advance(distance: Double, time: Double) -> [EngineEvent] {
        guard started, !finished, distance >= 0, time >= 0 else { return [] }
        var events: [EngineEvent] = []
        var d = distance
        var t = time

        while let step = currentStep {
            stepDistance += d
            stepTime += t
            totalDistance += d
            totalTime += t

            var carryD = 0.0
            var carryT = 0.0
            var complete = false

            switch step.end {
            case .distance(let target) where stepDistance >= target:
                carryD = stepDistance - target
                carryT = d > 0 ? t * min(1, carryD / d) : 0
                complete = true
            case .time(let target) where stepTime >= target:
                carryT = stepTime - target
                carryD = t > 0 ? d * min(1, carryT / t) : 0
                complete = true
            default:
                break
            }

            if complete {
                // Give the overshoot to the next step so totals stay honest.
                stepDistance -= carryD
                stepTime -= carryT
                totalDistance -= carryD
                totalTime -= carryT
                if case .time = step.end {
                    events += completeStep(trigger: .time)
                } else {
                    events += completeStep(trigger: .distance)
                }
                if finished || (carryD == 0 && carryT == 0) { break }
                d = carryD
                t = carryT
                continue
            }

            events += cues(for: step)
            break
        }
        return events
    }

    /// A free recording: one open step with no target, laps by hand until stopped.
    public var isFree: Bool {
        workout.steps.count == 1 && workout.steps[0].end == .open && workout.steps[0].target == nil
    }

    /// The runner tapped Lap: end the current step now. In a free recording the lap closes and
    /// recording carries on.
    public func manualLap() -> [EngineEvent] {
        guard started, !finished, let step = currentStep else { return [] }
        guard isFree else { return completeStep(trigger: .manual) }
        let lap = Lap(stepIndex: stepIndex, label: "Lap \(laps.count + 1)", distance: stepDistance,
                      duration: stepTime, kind: step.kind, trigger: .manual)
        laps.append(lap)
        stepDistance = 0
        stepTime = 0
        splitsAnnounced = 0
        lastSplitTime = 0
        var speech = "Lap \(laps.count)."
        if let p = lap.pace, lap.distance >= 200 {
            speech += options.sport.usesPace ? " \(Speech.pace(p)) per kilometre." : " \(Speech.speed(secondsPerKm: p))."
        }
        return [.lap(lap), .speak(speech)]
    }

    /// Close the current lap of a free recording under a name, without a word (route efforts
    /// lap themselves: "Easy" up to an effort, "Effort 2" over it).
    public func splitLap(label: String, kind: StepKind) -> [EngineEvent] {
        guard started, !finished, isFree, currentStep != nil, stepTime > 0 else { return [] }
        let lap = Lap(stepIndex: stepIndex, label: label, distance: stepDistance, duration: stepTime,
                      kind: kind, trigger: .distance)
        laps.append(lap)
        stepDistance = 0
        stepTime = 0
        splitsAnnounced = 0
        lastSplitTime = 0
        return [.lap(lap)]
    }

    /// The runner ended the session early.
    public func finishEarly() -> [EngineEvent] {
        guard started, !finished else { return [] }
        if let step = currentStep, stepTime > 0 {
            let label = isFree && !laps.isEmpty ? "Lap \(laps.count + 1)" : step.label
            let lap = Lap(stepIndex: stepIndex, label: label, distance: stepDistance, duration: stepTime,
                          kind: step.kind, trigger: .sessionEnd)
            laps.append(lap)
            finished = true
            return [
                .lap(lap),
                .speak("End of session. \(Speech.distance(totalDistance)) in \(Speech.duration(totalTime))."),
                .finished
            ]
        }
        finished = true
        return [
            .speak("End of session. \(Speech.distance(totalDistance)) in \(Speech.duration(totalTime))."),
            .finished
        ]
    }

    // MARK: - Internals

    private func completeStep(trigger: LapTrigger) -> [EngineEvent] {
        let step = workout.steps[stepIndex]
        let lap = Lap(stepIndex: stepIndex, label: step.label, distance: stepDistance, duration: stepTime,
                      kind: step.kind, trigger: currentStepIsLast ? .sessionEnd : trigger)
        laps.append(lap)

        var events: [EngineEvent] = [.lap(lap)]
        var speech = ""
        if options.lapPaceFeedback, let p = lap.pace, lap.distance >= 200 {
            if options.sport.usesPace {
                speech += "\(Speech.shortLabel(step.label)) done, \(Speech.pace(p)) per kilometre. "
            } else {
                speech += "\(Speech.shortLabel(step.label)) done, \(Speech.speed(secondsPerKm: p)). "
            }
        }

        stepIndex += 1
        stepDistance = 0
        stepTime = 0
        firedCues = []
        splitsAnnounced = 0
        lastSplitTime = 0

        if let next = currentStep {
            speech += Speech.intro(next)
            events.append(.speak(speech))
        } else {
            finished = true
            speech += "End of session. \(Speech.distance(totalDistance)) in \(Speech.duration(totalTime))."
            events.append(.speak(speech))
            events.append(.finished)
        }
        return events
    }

    /// Countdown cues (with a preview of the next step on the last one) and km splits.
    private func cues(for step: Step) -> [EngineEvent] {
        var out: [EngineEvent] = []

        // Splits on long steps.
        if options.kmSplits, isLong(step) {
            let every = options.sport.splitDistance
            let n = Int(stepDistance / every)
            if n > splitsAnnounced {
                splitsAnnounced = n
                let splitTime = stepTime - lastSplitTime
                lastSplitTime = stepTime
                if !nearEnd(step) {
                    let km = Int(Double(n) * every / 1000)
                    let label = km == 1 ? "1 kilometre" : "\(km) kilometres"
                    let perKm = splitTime / (every / 1000)
                    out.append(.speak(options.sport.usesPace ? "\(label), \(Speech.pace(perKm)) pace."
                                                             : "\(label), \(Speech.speed(secondsPerKm: perKm))."))
                }
            }
        }

        // Countdown.
        let thresholds: [Double]
        let remainingNow: Double
        switch step.end {
        case .distance(let target):
            thresholds = target >= 1500 ? [500, 100] : (target >= 400 ? [100] : [])
            remainingNow = target - stepDistance
        case .time(let target):
            thresholds = target >= 300 ? [60, 15] : (target >= 30 ? [15] : [])
            remainingNow = target - stepTime
        case .open:
            return out
        }

        let crossed = thresholds.filter { remainingNow <= $0 && !firedCues.contains(Int($0)) }
        guard let smallest = crossed.min() else { return out }
        for value in crossed { firedCues.insert(Int(value)) }

        var text: String
        if case .distance = step.end {
            text = "\(Int(smallest)) metres to go."
        } else {
            text = smallest >= 60 ? "1 minute to go." : "\(Int(smallest)) seconds."
        }
        if smallest == thresholds.last {
            if let next = nextStep {
                text += " Next, " + Speech.intro(next)
            } else {
                text += " Last one."
            }
        }
        out.append(.speak(text))
        return out
    }

    private var currentStepIsLast: Bool { stepIndex == workout.steps.count - 1 }

    private func isLong(_ step: Step) -> Bool {
        switch step.end {
        case .distance(let d): return d >= 2 * options.sport.splitDistance
        case .time(let t): return t >= 600
        case .open: return true
        }
    }

    private func nearEnd(_ step: Step) -> Bool {
        switch step.end {
        case .distance(let d): return d - stepDistance < 300
        case .time(let t): return t - stepTime < 45
        case .open: return false
        }
    }
}

public enum SessionSummary {
    /// Plain-text summary to share or paste back to Claude for logging.
    public static func text(workout: Workout, laps: [Lap], totalDistance: Double, totalTime: Double) -> String {
        var lines = ["Run Guide – \(workout.name)",
                     "Total \(Format.km(totalDistance)) in \(Format.clock(totalTime)) (\(Format.pace(totalDistance > 0 ? totalTime / (totalDistance / 1000) : nil))/km)",
                     ""]
        for (i, lap) in laps.enumerated() {
            lines.append("\(i + 1). \(lap.label): \(Format.km(lap.distance)) in \(Format.clock(lap.duration)) (\(Format.pace(lap.pace))/km)")
        }
        return lines.joined(separator: "\n")
    }
}
