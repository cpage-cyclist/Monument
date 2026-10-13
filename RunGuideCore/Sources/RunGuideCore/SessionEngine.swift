import Foundation

public struct Lap: Hashable {
    public let stepIndex: Int
    public let label: String
    public let distance: Double   // metres
    public let duration: Double   // seconds

    public init(stepIndex: Int, label: String, distance: Double, duration: Double) {
        self.stepIndex = stepIndex
        self.label = label
        self.distance = distance
        self.duration = duration
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

public struct EngineOptions: Equatable {
    /// Say the pace of each step when it finishes.
    public var lapPaceFeedback: Bool
    /// Say a split every km during long steps (≥ 2 km or ≥ 10 min).
    public var kmSplits: Bool

    public init(lapPaceFeedback: Bool = true, kmSplits: Bool = true) {
        self.lapPaceFeedback = lapPaceFeedback
        self.kmSplits = kmSplits
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
                events += completeStep()
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

    /// The runner tapped Lap: end the current step now.
    public func manualLap() -> [EngineEvent] {
        guard started, !finished, currentStep != nil else { return [] }
        return completeStep()
    }

    /// The runner ended the session early.
    public func finishEarly() -> [EngineEvent] {
        guard started, !finished else { return [] }
        if let step = currentStep, stepTime > 0 {
            laps.append(Lap(stepIndex: stepIndex, label: step.label, distance: stepDistance, duration: stepTime))
        }
        finished = true
        return [
            .speak("Session ended. \(Speech.distance(totalDistance)) in \(Speech.duration(totalTime))."),
            .finished
        ]
    }

    // MARK: - Internals

    private func completeStep() -> [EngineEvent] {
        let step = workout.steps[stepIndex]
        let lap = Lap(stepIndex: stepIndex, label: step.label, distance: stepDistance, duration: stepTime)
        laps.append(lap)

        var events: [EngineEvent] = [.lap(lap)]
        var speech = ""
        if options.lapPaceFeedback, let p = lap.pace, lap.distance >= 200 {
            speech += "\(Speech.shortLabel(step.label)) done, \(Speech.pace(p)) per kilometre. "
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
            speech += "Session complete. \(Speech.distance(totalDistance)) in \(Speech.duration(totalTime))."
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
            let km = Int(stepDistance / 1000)
            if km > splitsAnnounced {
                splitsAnnounced = km
                let splitTime = stepTime - lastSplitTime
                lastSplitTime = stepTime
                if !nearEnd(step) {
                    let label = km == 1 ? "1 kilometre" : "\(km) kilometres"
                    out.append(.speak("\(label), \(Speech.pace(splitTime)) pace."))
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

    private func isLong(_ step: Step) -> Bool {
        switch step.end {
        case .distance(let d): return d >= 2000
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
