import Foundation

/// How a step finishes. Each step ends on its own terms, so distance and
/// time steps can be mixed freely in one session.
public enum StepEnd: Hashable {
    /// Ends after this many metres (measured by GPS).
    case distance(Double)
    /// Ends after this many seconds (measured by the clock).
    case time(Double)
    /// Ends when the runner taps Lap.
    case open
}

/// What kind of effort a step is. Written into the FIT file as lap intensity,
/// so Intervals can tell reps from recoveries.
public enum StepKind: Hashable {
    case active, rest, warmup, cooldown
}

public struct Step: Hashable, Identifiable {
    public let id: Int
    /// What gets spoken and shown, e.g. "Rep 2 of 5" or "Float".
    public let label: String
    public let end: StepEnd
    /// The target as written in the session, e.g. "4:00/km" or "5:00-5:30/km".
    public let target: String?
    public let kind: StepKind

    public init(id: Int, label: String, end: StepEnd, target: String?, kind: StepKind = .active) {
        self.id = id
        self.label = label
        self.end = end
        self.target = target
        self.kind = kind
    }
}

public struct Workout: Hashable, Identifiable {
    public var id: String { name + "|" + String(steps.count) + "|" + String(plannedDistance) }
    public var name: String
    public var steps: [Step]

    public init(name: String, steps: [Step]) {
        self.name = name
        self.steps = steps
    }

    /// Sum of the distance-based steps only.
    public var plannedDistance: Double {
        steps.reduce(0) { total, step in
            if case .distance(let d) = step.end { return total + d }
            return total
        }
    }

    /// Sum of the time-based steps only.
    public var plannedTime: Double {
        steps.reduce(0) { total, step in
            if case .time(let t) = step.end { return total + t }
            return total
        }
    }
}
