import Foundation

// Mid-effort voice feedback: a short, factual line at 25, 50 and 75% of an effort block and a
// summary at the end, against the block's power or pace target. Blocks under two minutes get one
// line at 50% and nothing else.
//
// Rules the lines keep to:
// - Grounded, not judging: where you are against the target and which way it's moving, never
//   "good" or "too hard".
// - No numbers, and nothing about distance or how far through you are.
// - Each line follows on from the last checkpoint ("settled into it", "still above"), with a few
//   wordings per case picked at random.
// - Power and pace only. A step's own target range is the band; a single target gets ±3% power
//   or ±5 s/km pace.

/// What a block is measured against.
public enum FeedbackTarget: Equatable, Sendable {
    /// Watts.
    case power(ClosedRange<Double>)
    /// Seconds per km; the lower bound is the faster end.
    case pace(ClosedRange<Double>)

    /// The band a single target or a range gives.
    public static func powerBand(_ target: ClosedRange<Double>) -> FeedbackTarget {
        if target.upperBound - target.lowerBound < 1 {
            let w = (target.lowerBound + target.upperBound) / 2
            return .power((w * 0.97)...(w * 1.03))
        }
        return .power(target)
    }

    public static func paceBand(_ target: ClosedRange<Double>) -> FeedbackTarget {
        if target.upperBound - target.lowerBound < 1 {
            let p = (target.lowerBound + target.upperBound) / 2
            return .pace((p - 5)...(p + 5))
        }
        return .pace(target)
    }

    /// The target for a workout step: power when it has watts, else an absolute pace from its
    /// text. Effort steps only (not warm-ups, recoveries or cool-downs), and not ramps or HR.
    public static func forStep(_ step: Step) -> FeedbackTarget? {
        guard step.kind == .active, let text = step.target, !text.lowercased().contains("ramp") else { return nil }
        if let w = step.watts { return powerBand(w) }
        return pace(fromText: text)
    }

    /// The target for a route effort: watts (needs FTP for % and zones) or an absolute pace.
    public static func forEffort(_ effort: RouteEffort, ftp: Double?) -> FeedbackTarget? {
        guard !effort.max, let t = effort.target, !t.ramp else { return nil }
        if let w = effort.watts(ftp: ftp) { return powerBand(w) }
        if t.metric == .pace, t.mode == .absolute {
            let a = t.low, b = t.high ?? t.low
            return paceBand(min(a, b)...max(a, b))
        }
        return nil
    }

    static func pace(fromText text: String) -> FeedbackTarget? {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        for (i, token) in tokens.enumerated() {
            let next = tokens.indices.contains(i + 1) ? tokens[i + 1] : nil
            if let read = PlanTarget.read(token: token, next: next), read.target.metric == .pace,
               read.target.mode == .absolute {
                let a = read.target.low, b = read.target.high ?? read.target.low
                return paceBand(min(a, b)...max(a, b))
            }
        }
        return nil
    }
}

/// How a block's length is measured.
public enum FeedbackLength: Equatable, Sendable {
    case time(Double)
    case distance(Double)
}

/// Where the average sits against the band.
public enum FeedbackState: Equatable, Sendable { case under, on, over }
/// Which way the last 30 s are going against the block so far.
public enum FeedbackTrend: Equatable, Sendable { case steady, rising, falling }

/// Feedback for one effort block. Feed it every second; it returns a line when one is due.
public final class EffortFeedback {
    public let target: FeedbackTarget
    public let length: FeedbackLength
    /// Checkpoints as fractions of the block.
    public let checkpoints: [Double]
    /// Whether the block gets an end-of-block line.
    public let summarises: Bool

    private var samples: [(t: Double, watts: Double?, metres: Double)] = []
    private var elapsed = 0.0
    private var covered = 0.0
    private var reached = 0
    private var history: [FeedbackState] = []
    private let pick: (Int) -> Int

    /// Blocks under this many seconds only get the 50% line.
    public static let shortBlock = 120.0
    /// Trend threshold: last 30 s against the block average.
    static let trendRatio = 0.03

    /// `expectedSeconds` sizes a distance block (from its pace, or a typical speed).
    public init(target: FeedbackTarget, length: FeedbackLength, expectedSeconds: Double? = nil,
                pick: @escaping (Int) -> Int = { Int.random(in: 0..<$0) }) {
        self.target = target
        self.length = length
        self.pick = pick
        let seconds: Double
        switch length {
        case .time(let s): seconds = s
        case .distance(let d):
            if let e = expectedSeconds { seconds = e }
            else if case .pace(let band) = target { seconds = d / 1000 * (band.lowerBound + band.upperBound) / 2 }
            else { seconds = d / 8.33 }
        }
        let short = seconds < Self.shortBlock
        checkpoints = short ? [0.5] : [0.25, 0.5, 0.75]
        summarises = !short
    }

    /// One tick: seconds and metres since the last, and the watts now (nil without a power meter).
    public func add(seconds: Double, metres: Double, watts: Double?) -> String? {
        guard seconds > 0 else { return nil }
        elapsed += seconds
        covered += metres
        samples.append((elapsed, watts, covered))
        guard reached < checkpoints.count, fraction >= checkpoints[reached] else { return nil }
        // Several crossed at once (a long gap): speak only for the latest.
        while reached < checkpoints.count, fraction >= checkpoints[reached] { reached += 1 }
        guard let state = state(), let trend = trend() else { return nil }
        let line = FeedbackLines.checkpoint(previous: history.last, now: state, trend: trend, pick: pick)
        history.append(state)
        return line
    }

    /// The end-of-block line, for blocks long enough to have one.
    public func finish() -> String? {
        guard summarises, let state = state() else { return nil }
        let throughout = !history.isEmpty && history.allSatisfy { $0 == state }
        return FeedbackLines.summary(state, throughout: throughout, pick: pick)
    }

    var fraction: Double {
        switch length {
        case .time(let s): return s > 0 ? elapsed / s : 0
        case .distance(let d): return d > 0 ? covered / d : 0
        }
    }

    // MARK: - Measuring

    /// The block's average against the band. Nil until there's something to go on.
    func state() -> FeedbackState? {
        switch target {
        case .power(let band):
            guard let avg = averageWatts(since: 0) else { return nil }
            return avg < band.lowerBound ? .under : (avg > band.upperBound ? .over : .on)
        case .pace(let band):
            guard let pace = averagePace(since: 0) else { return nil }
            // Slower (more seconds) is under.
            return pace > band.upperBound ? .under : (pace < band.lowerBound ? .over : .on)
        }
    }

    /// The last 30 s against the block so far. Steady until there's enough block to compare with.
    func trend() -> FeedbackTrend? {
        guard elapsed >= 45 else { return .steady }
        let since = elapsed - 30
        let ratio: Double
        switch target {
        case .power:
            guard let all = averageWatts(since: 0), all > 0, let recent = averageWatts(since: since) else { return .steady }
            ratio = recent / all
        case .pace:
            // Compare speeds so that "rising" means going harder for both.
            guard let all = averagePace(since: 0), let recent = averagePace(since: since), recent > 0 else { return .steady }
            ratio = all / recent
        }
        if ratio > 1 + Self.trendRatio { return .rising }
        if ratio < 1 - Self.trendRatio { return .falling }
        return .steady
    }

    private func averageWatts(since t: Double) -> Double? {
        let w = samples.filter { $0.t > t }.compactMap(\.watts)
        return w.isEmpty ? nil : w.reduce(0, +) / Double(w.count)
    }

    /// Seconds per km over the samples after `t`; nil until 20 m have been covered.
    private func averagePace(since t: Double) -> Double? {
        let before = samples.last { $0.t <= t } ?? (t: 0, watts: nil, metres: 0)
        guard let last = samples.last else { return nil }
        let metres = last.metres - before.metres, seconds = last.t - before.t
        guard metres >= 20, seconds > 0 else { return nil }
        return seconds / (metres / 1000)
    }
}

/// Every line feedback can say. No numbers, no distances, no verdicts.
public enum FeedbackLines {
    /// A checkpoint line, following on from the one before.
    public static func checkpoint(previous: FeedbackState?, now: FeedbackState, trend: FeedbackTrend,
                                  pick: (Int) -> Int) -> String {
        choose(lines(previous: previous, now: now, trend: trend), pick)
    }

    public static func summary(_ state: FeedbackState, throughout: Bool, pick: (Int) -> Int) -> String {
        let options: [String]
        switch (state, throughout) {
        case (.on, true): options = ["On target the whole way.", "In the band from start to finish.", "Held the target throughout."]
        case (.on, false): options = ["On target overall.", "That one averaged on target.", "Finished in the band overall."]
        case (.over, true): options = ["Above target the whole way.", "Over the band from start to finish."]
        case (.over, false): options = ["Above target overall.", "That one averaged above target.", "Finished over the band overall."]
        case (.under, true): options = ["Below target the whole way.", "Under the band from start to finish."]
        case (.under, false): options = ["Below target overall.", "That one averaged below target.", "Finished under the band overall."]
        }
        return choose(options, pick)
    }

    static func lines(previous: FeedbackState?, now: FeedbackState, trend: FeedbackTrend) -> [String] {
        switch (previous, now, trend) {
        // First word on the block.
        case (nil, .on, .steady): return ["On target.", "Right in the band.", "Sitting on target."]
        case (nil, .on, .rising): return ["On target, and building.", "In the band, and lifting."]
        case (nil, .on, .falling): return ["On target, easing off.", "In the band, but dropping back."]
        case (nil, .over, .falling): return ["Above target, coming back down.", "Over the band, settling now."]
        case (nil, .over, _): return ["Above target.", "Started above the band.", "Over the band so far."]
        case (nil, .under, .rising): return ["Below target, coming up.", "Under the band, building."]
        case (nil, .under, _): return ["Below target.", "Under the band so far.", "Started below target."]

        // Held it.
        case (.on?, .on, .steady): return ["Still on target.", "Holding the band.", "Steady on target."]
        case (.on?, .on, .rising): return ["Still on target, and building.", "Holding the band, lifting a touch."]
        case (.on?, .on, .falling): return ["Still on target, easing off.", "Holding the band, but dropping back."]
        // Came into the band.
        case (.over?, .on, _): return ["Settled into the band.", "Back on target now.", "Down onto target."]
        case (.under?, .on, _): return ["Up into the band.", "On target now.", "Built up onto target."]
        // Left the band.
        case (.on?, .over, _): return ["Drifting above target.", "Edging over the band.", "Now above target."]
        case (.on?, .under, _): return ["Slipping below target.", "Dropping under the band.", "Now below target."]
        // Stayed out of it.
        case (.over?, .over, .falling): return ["Still above target, coming back down.", "Over the band, but settling."]
        case (.over?, .over, _): return ["Still above target.", "Holding above the band.", "Still over the band."]
        case (.under?, .under, .rising): return ["Still below target, coming up.", "Under the band, but building."]
        case (.under?, .under, _): return ["Still below target.", "Still under the band.", "Holding below target."]
        // Crossed right over.
        case (.under?, .over, _): return ["Now above target.", "Gone from under to over the band."]
        case (.over?, .under, _): return ["Now below target.", "Dropped under the band."]
        }
    }

    private static func choose(_ options: [String], _ pick: (Int) -> Int) -> String {
        options[min(max(pick(options.count), 0), options.count - 1)]
    }
}
