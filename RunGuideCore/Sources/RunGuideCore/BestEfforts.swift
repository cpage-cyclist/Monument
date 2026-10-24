import Foundation

/// Which ranking a medal comes from.
public enum BestPeriod: String, Sendable, Equatable {
    /// The last 365 days.
    case year
    /// Everything on Intervals.
    case allTime
}

/// A top-three placing for an effort: 1st, 2nd or 3rd best over a period.
public struct EffortMedal: Equatable, Sendable {
    public let period: BestPeriod
    /// 1, 2 or 3.
    public let place: Int

    public init(period: BestPeriod, place: Int) {
        self.period = period
        self.place = place
    }

    /// e.g. "2nd best all time", "Best this year".
    public var description: String {
        let rank = place == 1 ? "Best" : (place == 2 ? "2nd best" : "3rd best")
        return rank + (period == .allTime ? " all time" : " this year")
    }
}

/// A best-power curve with its top three efforts per duration and the activities they came from,
/// as Intervals returns from `power-curves` with `subMaxEfforts=2`.
public struct RankedCurve: Decodable, Sendable, Equatable {
    public let id: String?
    public let secs: [Int]
    /// Activity of the best effort at each duration.
    public let activityID: [String?]
    /// Activities of the 2nd and 3rd best efforts at each duration (`[duration][place - 2]`).
    public let runnersUp: [[String?]]

    enum CodingKeys: String, CodingKey {
        case id, secs, values
        case activityID = "activity_id"
        case submaxActivityID = "submax_activity_id"
    }

    public init(id: String?, secs: [Int], activityID: [String?], runnersUp: [[String?]]) {
        self.id = id
        self.secs = secs
        self.activityID = activityID
        self.runnersUp = runnersUp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        secs = try c.decodeIfPresent([Int].self, forKey: .secs) ?? []
        activityID = try c.decodeIfPresent([String?].self, forKey: .activityID) ?? []
        let submax = try c.decodeIfPresent([[String?]].self, forKey: .submaxActivityID) ?? []
        runnersUp = RankedCurve.perDuration(submax, durations: secs.count)
    }

    /// Intervals' sub-max arrays may come per duration (`[duration][k]`) or per place
    /// (`[k][duration]`); this always returns them per duration.
    static func perDuration(_ submax: [[String?]], durations: Int) -> [[String?]] {
        guard !submax.isEmpty, durations > 0 else { return [] }
        if submax.count == durations { return submax }
        // Per place: transpose.
        guard submax.allSatisfy({ $0.count == durations }) else { return [] }
        return (0..<durations).map { i in submax.map { $0[i] } }
    }

    /// 1, 2 or 3 if the activity holds that place at exactly `seconds`, else nil.
    public func place(of activity: String, at seconds: Int) -> Int? {
        guard let i = secs.firstIndex(of: seconds) else { return nil }
        if activityID.indices.contains(i), activityID[i] == activity { return 1 }
        if runnersUp.indices.contains(i) {
            for (k, id) in runnersUp[i].prefix(2).enumerated() where id == activity {
                return k + 2
            }
        }
        return nil
    }

    /// Decodes the endpoint's `{"list": [...]}` (or a bare array).
    public static func decodeAll(_ data: Data) throws -> [RankedCurve] {
        struct Wrapper: Decodable { let list: [RankedCurve]? }
        if let wrapped = try? JSONDecoder().decode(Wrapper.self, from: data), let list = wrapped.list {
            return list
        }
        return try JSONDecoder().decode([RankedCurve].self, from: data)
    }
}

/// The year and all-time rankings, matched to their curves.
public struct BestEffortRanks: Sendable, Equatable {
    public let year: RankedCurve?
    public let allTime: RankedCurve?

    public init(year: RankedCurve?, allTime: RankedCurve?) {
        self.year = year
        self.allTime = allTime
    }

    /// Curves requested as `curves=1y,all`, matched by id, falling back to their order.
    public init(curves: [RankedCurve]) {
        let year = curves.first { $0.id == "1y" }
        let all = curves.first { $0.id == "all" }
        if year != nil || all != nil {
            self.init(year: year, allTime: all)
        } else {
            self.init(year: curves.first, allTime: curves.count > 1 ? curves[1] : nil)
        }
    }

    /// The medal an effort earns. An all-time placing outranks any yearly one.
    public func medal(activity: String, seconds: Int) -> EffortMedal? {
        if let place = allTime?.place(of: activity, at: seconds) {
            return EffortMedal(period: .allTime, place: place)
        }
        if let place = year?.place(of: activity, at: seconds) {
            return EffortMedal(period: .year, place: place)
        }
        return nil
    }
}
