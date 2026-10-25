import Foundation

// Sport-agnostic recording: the sport a recording is locked to, power and cadence maths, the
// Bluetooth cycling sensor formats, and turning a workout from Intervals into a session to play.

/// What's being recorded. Chosen before starting and fixed for the session.
public enum RecordSport: String, CaseIterable, Codable, Sendable, Identifiable {
    case run, ride, walk

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .run: "Run"
        case .ride: "Ride"
        case .walk: "Walk"
        }
    }

    /// SF Symbol.
    public var icon: String {
        switch self {
        case .run: "figure.run"
        case .ride: "figure.outdoor.cycle"
        case .walk: "figure.walk"
        }
    }

    /// FIT `sport`: running 1, cycling 2, walking 11.
    public var fitSport: UInt64 {
        switch self {
        case .run: 1
        case .ride: 2
        case .walk: 11
        }
    }

    /// Strava `sport_type`.
    public var stravaType: String { title }

    /// The sport for an Intervals activity type, if Record handles it.
    public init?(intervalsType type: String?) {
        guard let match = Self.allCases.first(where: { $0.matches(intervalsType: type) }) else { return nil }
        self = match
    }

    /// Planned Intervals sessions of these types are offered for this sport.
    public func matches(intervalsType type: String?) -> Bool {
        let t = (type ?? "").lowercased()
        switch self {
        case .run: return t.contains("run")
        case .ride: return t.contains("ride")
        case .walk: return t.contains("walk") || t.contains("hike")
        }
    }

    /// Pace on screen and in speech; rides use speed.
    public var usesPace: Bool { self != .ride }
    /// Power and cadence sensors are offered.
    public var usesPower: Bool { self == .ride }

    /// Route cue distances: a bike needs much earlier warning than a runner.
    public var routeHeadsUp: Double { self == .ride ? 500 : 100 }
    public var routeNow: Double { self == .ride ? 40 : 15 }
    public var routeChain: Double { self == .ride ? 150 : 70 }

    /// Spoken splits on long steps: every km on foot, every 5 km on the bike.
    public var splitDistance: Double { self == .ride ? 5000 : 1000 }
}

// MARK: - Power

public enum PowerMath {
    /// Normalised power from 1-second samples: 30 s rolling mean, to the 4th power, averaged,
    /// 4th root. Needs at least 30 samples.
    public static func normalized(_ watts: [Int]) -> Int? {
        guard watts.count >= 30 else { return nil }
        var window = 0.0
        var total = 0.0
        var count = 0
        for (i, w) in watts.enumerated() {
            window += Double(w)
            if i >= 30 { window -= Double(watts[i - 30]) }
            if i >= 29 {
                total += pow(window / 30, 4)
                count += 1
            }
        }
        return Int(pow(total / Double(count), 0.25).rounded())
    }

    public static func average(_ values: [Int]) -> Int? {
        values.isEmpty ? nil : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }
}

/// Intervals' default power zones as % of FTP, for showing a zone target in watts.
public enum PowerZones {
    public static let bounds: [(Double, Double)] = [
        (0, 55), (56, 75), (76, 90), (91, 105), (106, 120), (121, 150), (151, 200)
    ]

    public static func percent(zone: Int) -> (Double, Double) {
        bounds[min(max(zone - 1, 0), bounds.count - 1)]
    }
}

extension PlanTarget {
    /// The watts this target asks for, given FTP. Nil for heart-rate and pace targets.
    public func watts(ftp: Double) -> ClosedRange<Double>? {
        guard metric == .power else { return nil }
        switch mode {
        case .absolute:
            let a = low, b = high ?? low
            return min(a, b)...max(a, b)
        case .percent:
            let a = low * ftp / 100, b = (high ?? low) * ftp / 100
            return min(a, b)...max(a, b)
        case .zone:
            let lo = PowerZones.percent(zone: Int(low)).0, hi = PowerZones.percent(zone: Int(high ?? low)).1
            return (lo * ftp / 100)...(hi * ftp / 100)
        }
    }
}

// MARK: - Bluetooth cycling sensors

/// Cycling Power Measurement (characteristic 0x2A63): flags, instantaneous power, then optional
/// fields in a fixed order. Only power and crank revolutions (for cadence) are kept.
public struct CyclingPowerReading: Equatable, Sendable {
    public let watts: Int
    public let crank: CrankData?

    public static func parse(_ data: Data) -> CyclingPowerReading? {
        let b = [UInt8](data)
        guard b.count >= 4 else { return nil }
        let flags = UInt16(b[0]) | UInt16(b[1]) << 8
        let power = Int(Int16(bitPattern: UInt16(b[2]) | UInt16(b[3]) << 8))
        var i = 4
        func has(_ bit: Int) -> Bool { flags & (1 << bit) != 0 }
        if has(0) { i += 1 }        // pedal power balance
        if has(2) { i += 2 }        // accumulated torque
        if has(4) { i += 6 }        // wheel revolutions + last wheel event time
        var crank: CrankData?
        if has(5) {
            guard b.count >= i + 4 else { return CyclingPowerReading(watts: max(power, 0), crank: nil) }
            crank = CrankData(revolutions: UInt16(b[i]) | UInt16(b[i + 1]) << 8,
                              eventTime: UInt16(b[i + 2]) | UInt16(b[i + 3]) << 8)
        }
        return CyclingPowerReading(watts: max(power, 0), crank: crank)
    }
}

/// Cumulative crank revolutions and the time of the last one (1/1024 s, wrapping at 64 s).
public struct CrankData: Equatable, Sendable {
    public let revolutions: UInt16
    public let eventTime: UInt16

    public init(revolutions: UInt16, eventTime: UInt16) {
        self.revolutions = revolutions
        self.eventTime = eventTime
    }

    /// From a CSC Measurement (characteristic 0x2A5B): flags byte, optional wheel data (6 bytes),
    /// optional crank data (4 bytes).
    public static func parseCSC(_ data: Data) -> CrankData? {
        let b = [UInt8](data)
        guard let flags = b.first else { return nil }
        var i = 1
        if flags & 0x01 != 0 { i += 6 }
        guard flags & 0x02 != 0, b.count >= i + 4 else { return nil }
        return CrankData(revolutions: UInt16(b[i]) | UInt16(b[i + 1]) << 8,
                         eventTime: UInt16(b[i + 2]) | UInt16(b[i + 3]) << 8)
    }
}

/// Cadence from successive crank readings. Sensors repeat the last event when the cranks haven't
/// turned, so cadence drops to zero once nothing new has arrived for a few seconds.
public struct CadenceCalculator: Sendable {
    private var last: CrankData?
    private var lastChange: Date?
    public private(set) var rpm: Int?

    public init() {}

    public mutating func update(_ crank: CrankData, at now: Date) -> Int? {
        guard let previous = last else {
            last = crank
            lastChange = now
            return rpm
        }
        last = crank
        let revs = crank.revolutions &- previous.revolutions
        let ticks = crank.eventTime &- previous.eventTime
        if revs > 0, ticks > 0 {
            let value = Double(revs) / (Double(ticks) / 1024) * 60
            if value < 250 { rpm = Int(value.rounded()) }
            lastChange = now
        } else if let lastChange, now.timeIntervalSince(lastChange) > 3 {
            rpm = 0
        }
        return rpm
    }
}

/// A rolling average over the last few seconds of readings (3 s power on screen).
public struct RollingAverage: Sendable {
    public let seconds: TimeInterval
    private var samples: [(Date, Double)] = []

    public init(seconds: TimeInterval) { self.seconds = seconds }

    public mutating func add(_ value: Double, at time: Date) {
        samples.append((time, value))
        samples.removeAll { time.timeIntervalSince($0.0) > seconds }
    }

    public func value(at now: Date) -> Double? {
        let recent = samples.filter { now.timeIntervalSince($0.0) <= seconds }
        guard !recent.isEmpty else { return nil }
        return recent.map(\.1).reduce(0, +) / Double(recent.count)
    }
}

// MARK: - Playing a workout

extension Workout {
    /// A session to play from an Intervals workout: repeats unrolled, labels and kinds as the run
    /// player has always used them, targets kept as text to speak, and power targets in watts.
    public init(plan: WorkoutPlan, ftp: Double?) {
        var steps: [Step] = []
        func add(_ label: String, _ step: PlanStep, _ kind: StepKind) {
            let end: StepEnd
            switch step.length {
            case .time(let s): end = s > 0 ? .time(s) : .open
            case .distance(let d): end = .distance(d)
            }
            let watts = ftp.flatMap { step.target?.watts(ftp: $0) }
            let said = [step.target?.text, step.cadence?.text].compactMap { $0 }.joined(separator: " ")
            steps.append(Step(id: steps.count, label: label, end: end, target: said.isEmpty ? nil : said,
                              kind: kind, watts: watts))
        }

        for block in plan.blocks {
            let title = block.title.trimmingCharacters(in: .whitespaces)
            let section = WorkoutParser.kind(forSection: title)
            if block.repeats > 1 {
                let n = block.repeats
                for rep in 1...n {
                    for (j, step) in block.steps.enumerated() {
                        let label: String
                        if j == 0 {
                            label = step.cue.isEmpty ? "Rep \(rep) of \(n)" : "Rep \(rep) of \(n), \(step.cue)"
                        } else if !step.cue.isEmpty {
                            label = step.cue
                        } else {
                            label = block.steps.count == 2 ? "Recovery" : "Rep \(rep) of \(n), part \(j + 1)"
                        }
                        add(label, step, j == 0 ? .active : .rest)
                    }
                }
            } else {
                for step in block.steps {
                    let label = !step.cue.isEmpty ? step.cue : (title.isEmpty ? "Step \(steps.count + 1)" : title)
                    add(label, step, section)
                }
            }
        }
        self.init(name: plan.name.isEmpty ? "Session" : plan.name, steps: steps)
    }

    /// One open step: record until stopped, laps by hand.
    public static func justRecord(_ sport: RecordSport) -> Workout {
        Workout(name: sport.title, steps: [Step(id: 0, label: sport.title, end: .open, target: nil)])
    }
}
