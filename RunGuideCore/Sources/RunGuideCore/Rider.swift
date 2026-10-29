import Foundation

// The Rider tab: a top-trumps card of best efforts and the numbers that sum a rider up.

/// The span the card's best efforts cover.
public enum RiderPeriod: String, CaseIterable, Sendable, Identifiable {
    case days42, year, allTime

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .days42: "42 days"
        case .year: "Year"
        case .allTime: "All time"
        }
    }

    /// Intervals' `curves` code.
    public var curve: String {
        switch self {
        case .days42: "42d"
        case .year: "1y"
        case .allTime: "all"
        }
    }

    /// Curves asked for in one request: the three periods plus the 90 days Monument fits CP/W′ to.
    public static let request = ["42d", "90d", "1y", "all"]
}

public struct RiderEffort: Equatable, Sendable, Identifiable {
    public let seconds: Int
    public let watts: Double
    public let activity: String?
    public var id: Int { seconds }

    public init(seconds: Int, watts: Double, activity: String? = nil) {
        self.seconds = seconds
        self.watts = watts
        self.activity = activity
    }

    /// "5s", "1m", "5m", "20m".
    public var label: String { seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m" }

    public func wattsPerKg(_ weight: Double?) -> Double? {
        guard let weight, weight > 0 else { return nil }
        return watts / weight
    }
}

public enum RiderCard {
    /// The durations on the card.
    public static let durations = [5, 60, 300, 1200]

    public static func efforts(_ curve: PowerCurve?) -> [RiderEffort] {
        guard let curve else { return [] }
        return durations.compactMap { s in
            curve.watts(at: s).map { RiderEffort(seconds: s, watts: $0, activity: curve.activity(at: s)) }
        }
    }

    /// Curves keyed by their code. Intervals labels each with its `id`; if it doesn't, they're taken
    /// in the order asked for.
    public static func byPeriod(_ curves: [PowerCurve], requested: [String] = RiderPeriod.request) -> [String: PowerCurve] {
        var out: [String: PowerCurve] = [:]
        for (i, c) in curves.enumerated() {
            if let id = c.id, requested.contains(id) {
                out[id] = c
            } else if requested.indices.contains(i), out[requested[i]] == nil {
                out[requested[i]] = c
            }
        }
        return out
    }

    /// Estimated VO₂max (ml/kg/min) from best 5-minute power, using the ACSM leg-cycling equation
    /// (10.8 × W/kg + 7). An estimate only: it reads high or low depending on efficiency.
    public static func vo2max(fiveMinuteWatts: Double?, weight: Double?) -> Double? {
        guard let w = fiveMinuteWatts, let kg = weight, kg > 0 else { return nil }
        return 10.8 * w / kg + 7
    }
}

/// This year's totals. Time and load cover every sport; distance and climbing are rides only.
public struct SeasonTotals: Equatable, Sendable {
    public var seconds: Double = 0
    public var load: Double = 0
    public var rideMetres: Double = 0
    public var climbing: Double = 0
    public var activities = 0

    public init() {}

    public init(_ activities: [ActivitySummary], year: String) {
        for a in activities where !a.isStravaPlaceholder && (a.startDateLocal ?? "").hasPrefix(year) {
            self.activities += 1
            seconds += a.movingTime ?? 0
            load += a.trainingLoad ?? 0
            if (a.type ?? "").lowercased().contains("ride") {
                rideMetres += a.distance ?? 0
                climbing += a.totalElevationGain ?? 0
            }
        }
    }
}

/// The bits of /athlete/{id} the card uses. Everything is optional so a changed field never
/// stops the card loading.
public struct AthleteProfile: Decodable, Sendable, Equatable {
    public let name: String?
    public let weight: Double?
    public let sportSettings: [SportSettings]?

    public struct SportSettings: Decodable, Sendable, Equatable {
        public let types: [String]?
        public let ftp: Double?
        public let wPrime: Double?
        public let lthr: Double?
        public let maxHR: Double?

        enum CodingKeys: String, CodingKey {
            case types, ftp, lthr
            case wPrime = "w_prime"
            case maxHR = "max_hr"
        }
    }

    enum CodingKeys: String, CodingKey {
        case name, sportSettings
        case weight = "icu_weight"
    }

    public init(name: String?, weight: Double?, sportSettings: [SportSettings]?) {
        self.name = name
        self.weight = weight
        self.sportSettings = sportSettings
    }

    /// Settings for rides.
    public var ride: SportSettings? {
        sportSettings?.first { ($0.types ?? []).contains { $0.lowercased().contains("ride") } } ?? sportSettings?.first
    }
}

// MARK: - Thresholds for the period on show

/// One ride's day (and the FTP and weight Intervals stamped on it), so each best effort can be
/// divided by the weight on the day it was ridden.
public struct RideThreshold: Equatable, Sendable {
    public let activity: String
    /// yyyy-MM-dd.
    public let day: String
    public let ftp: Double?
    public let weight: Double?

    public init(activity: String, day: String, ftp: Double?, weight: Double?) {
        self.activity = activity
        self.day = day
        self.ftp = ftp
        self.weight = weight
    }

    /// Rides from an activity list, oldest first.
    public static func rides(_ activities: [ActivitySummary]) -> [RideThreshold] {
        activities.compactMap { a -> RideThreshold? in
            guard !a.isStravaPlaceholder, (a.type ?? "").lowercased().contains("ride"),
                  let day = a.startDateLocal.map({ String($0.prefix(10)) }) else { return nil }
            return RideThreshold(activity: a.id.value, day: day, ftp: a.ftp, weight: a.weight)
        }
        .sorted { $0.day < $1.day }
    }

    /// Weigh-ins from wellness days, keyed by day.
    public static func weighIns(_ days: [WellnessDay]) -> [String: Double] {
        var out: [String: Double] = [:]
        for d in days { if let w = d.weight, w > 0 { out[d.id] = w } }
        return out
    }

    /// A weight for each ride from the weigh-ins either side of it: a straight line between the
    /// two, the first weigh-in before any were logged, and the latest carried forward after it.
    /// The weight Intervals stamps on a ride isn't used: back-dating a weigh-in only changes that
    /// day, so rides in between keep a stale default (or whatever Zwift or Wahoo sent). With no
    /// weigh-ins at all this is empty and the card uses today's weight.
    public static func weights(_ rides: [RideThreshold], weighIns: [String: Double]) -> [String: Double] {
        let ins = weighIns.compactMap { e in dayNumber(e.key).map { ($0, e.value) } }.sorted { $0.0 < $1.0 }
        guard let first = ins.first, let last = ins.last else { return [:] }
        var out: [String: Double] = [:]
        for r in rides {
            guard let n = dayNumber(r.day) else { continue }
            if n <= first.0 { out[r.activity] = first.1; continue }
            if n >= last.0 { out[r.activity] = last.1; continue }
            guard let i = ins.firstIndex(where: { $0.0 >= n }) else { continue }
            let (d1, w1) = ins[i], (d0, w0) = ins[i - 1]
            out[r.activity] = d1 == n ? w1 : w0 + (w1 - w0) * Double(n - d0) / Double(d1 - d0)
        }
        return out
    }

    /// Whole days since 1970 for "yyyy-MM-dd", calendar-safe across clock changes.
    static func dayNumber(_ day: String) -> Int? {
        let parts = day.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = DateComponents()
        c.year = parts[0]
        c.month = parts[1]
        c.day = parts[2]
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let date = cal.date(from: c) else { return nil }
        return Int((date.timeIntervalSince1970 / 86400).rounded())
    }
}

/// The thresholds the card shows for a period.
public struct RiderThresholds: Equatable, Sendable {
    /// Intervals' FTP: today's setting, shown only for comparison. The card leads with Monument's
    /// fit; hand-set values aren't a record of what was ridden.
    public var intervalsFTP: Double?
    /// Monument's fit to the period's own curve, or the 90-day fit when that curve won't fit.
    public var monument: PowerProfile?
    /// True when the period's curve couldn't be fitted and the 90-day fit stands in.
    public var monumentIs90d: Bool

    public init(intervalsFTP: Double?, monument: PowerProfile?, monumentIs90d: Bool = false) {
        self.intervalsFTP = intervalsFTP
        self.monument = monument
        self.monumentIs90d = monumentIs90d
    }
}

extension RiderCard {
    /// Monument's profile for every curve, worked out once per new set of curves.
    public static func fitAll(_ curves: [String: PowerCurve]) -> [String: PowerProfile] {
        curves.compactMapValues { PowerProfile.fitBest(curve: $0) }
    }

    public static func thresholds(period: RiderPeriod, profiles: [String: PowerProfile],
                                  currentFTP: Double?) -> RiderThresholds {
        let own = profiles[period.curve]
        let fallback = own == nil ? profiles["90d"] : nil
        return RiderThresholds(intervalsFTP: currentFTP, monument: own ?? fallback,
                               monumentIs90d: own == nil && fallback != nil)
    }

    /// The weight to divide an effort by: the weight on the ride that set it, else `fallback`.
    public static func weight(for effort: RiderEffort?, rideWeights: [String: Double], fallback: Double?) -> Double? {
        effort?.activity.flatMap { rideWeights[$0] } ?? fallback
    }
}

// MARK: - Rider type

/// The rider types of Coggan's power profile, read from the shape of 5 s, 1 min, 5 min and FTP W/kg.
public enum RiderType: String, Sendable, CaseIterable {
    case allRounder = "All-rounder"
    case sprinter = "Sprinter"
    case pursuiter = "Pursuiter"
    case timeTriallist = "Time triallist"
}

public struct RiderClassification: Equatable, Sendable {
    public let type: RiderType
    /// The duration the rider stands out at (3600 for FTP), shown as the hero.
    public let lead: Int
    public let wattsPerKg: Double
    /// Each duration's place on Coggan's table, 0 (untrained) to 1 (world class).
    public let scores: [Int: Double]

    /// "5 s", "1 min", "5 min", "FTP".
    public var leadLabel: String {
        switch lead {
        case 3600: "FTP"
        case ..<60: "\(lead) s"
        default: "\(lead / 60) min"
        }
    }
}

/// Coggan's power profile table (men), from untrained to world class at each duration.
public enum CogganProfile {
    /// W/kg at the bottom and top of the table. FTP is keyed as 3600.
    public static let ranges: [Int: (low: Double, high: Double)] = [
        5: (10.17, 25.18), 60: (5.64, 11.50), 300: (2.33, 7.60), 3600: (1.86, 6.40)
    ]
    public static let durations = [5, 60, 300, 3600]
    /// Scores closer together than this read as a flat profile.
    public static let flatSpread = 0.08

    public static func score(seconds: Int, wattsPerKg: Double) -> Double? {
        guard let r = ranges[seconds] else { return nil }
        return min(max((wattsPerKg - r.low) / (r.high - r.low), 0), 1)
    }

    /// Needs all four durations. The type comes from where the profile peaks: an FTP peak is a
    /// time triallist; a 5 s peak a sprinter; a 1 min peak a sprinter if the sprint outranks 5 min,
    /// else a pursuiter; a 5 min peak a pursuiter. A flat profile is an all-rounder, led by FTP.
    public static func classify(_ wkg: [Int: Double]) -> RiderClassification? {
        var scores: [Int: Double] = [:]
        for d in durations {
            guard let w = wkg[d], w > 0, let s = score(seconds: d, wattsPerKg: w) else { return nil }
            scores[d] = s
        }
        let top = durations.max { scores[$0]! < scores[$1]! }!
        let spread = scores[top]! - scores.values.min()!
        let type: RiderType
        if spread < flatSpread {
            type = .allRounder
        } else {
            switch top {
            case 3600: type = .timeTriallist
            case 5: type = .sprinter
            case 60: type = scores[5]! > scores[300]! ? .sprinter : .pursuiter
            default: type = .pursuiter
            }
        }
        let lead = type == .allRounder ? 3600 : top
        return RiderClassification(type: type, lead: lead, wattsPerKg: wkg[lead]!, scores: scores)
    }
}
