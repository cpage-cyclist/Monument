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

/// One ride's FTP and weight as Intervals recorded them, so the card's longer periods can show
/// the FTP held then and divide each best effort by the weight on the ride that set it.
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

    /// Rides from an activity list that carry an FTP or a weight, oldest first.
    public static func rides(_ activities: [ActivitySummary]) -> [RideThreshold] {
        activities.compactMap { a -> RideThreshold? in
            guard !a.isStravaPlaceholder, (a.type ?? "").lowercased().contains("ride"),
                  let day = a.startDateLocal.map({ String($0.prefix(10)) }),
                  a.ftp != nil || a.weight != nil else { return nil }
            return RideThreshold(activity: a.id.value, day: day, ftp: a.ftp, weight: a.weight)
        }
        .sorted { $0.day < $1.day }
    }

    /// The highest FTP on any ride from `day` on (all rides when nil), taken from the first ride
    /// that carried it, with that ride's weight.
    public static func peak(_ rides: [RideThreshold], from day: String?) -> RideThreshold? {
        var best: RideThreshold?
        for r in rides where day.map({ r.day >= $0 }) ?? true {
            guard let f = r.ftp, f > 0 else { continue }
            if f > (best?.ftp ?? 0) { best = r }
        }
        return best
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
    /// Intervals FTP: today's setting over 42 days; over a year or all time, the highest FTP set
    /// on any ride in the span (or today's setting if that's higher).
    public var intervalsFTP: Double?
    /// The ride the period's Intervals FTP was first carried on; nil when it's today's setting.
    /// Its weight comes from `RideThreshold.weights`, not the ride's own stamp.
    public var intervalsFTPRide: RideThreshold?
    /// Monument's fit to the period's own curve, or the 90-day fit when that curve won't fit.
    public var monument: PowerProfile?
    /// True when the period's curve couldn't be fitted and the 90-day fit stands in.
    public var monumentIs90d: Bool

    public init(intervalsFTP: Double?, intervalsFTPRide: RideThreshold? = nil,
                monument: PowerProfile?, monumentIs90d: Bool = false) {
        self.intervalsFTP = intervalsFTP
        self.intervalsFTPRide = intervalsFTPRide
        self.monument = monument
        self.monumentIs90d = monumentIs90d
    }
}

extension RiderCard {
    /// Monument's profile for every curve, worked out once per new set of curves.
    public static func fitAll(_ curves: [String: PowerCurve]) -> [String: PowerProfile] {
        curves.compactMapValues { PowerProfile.fitBest(curve: $0) }
    }

    /// First day a period covers, for matching rides to it: the curve's own start where Intervals
    /// sends one, else 365 days back for a year; nil for all time and 42 days (today's setting).
    public static func startDay(_ period: RiderPeriod, curve: PowerCurve?, today: Date = Date()) -> String? {
        switch period {
        case .days42, .allTime: return nil
        case .year:
            if let s = curve?.startDateLocal, s.count >= 10 { return String(s.prefix(10)) }
            return IntervalsDates.day(today.addingTimeInterval(-365 * 86400))
        }
    }

    public static func thresholds(period: RiderPeriod, curves: [String: PowerCurve],
                                  profiles: [String: PowerProfile], currentFTP: Double?,
                                  rides: [RideThreshold], today: Date = Date()) -> RiderThresholds {
        let own = profiles[period.curve]
        let fallback = own == nil ? profiles["90d"] : nil
        var t = RiderThresholds(intervalsFTP: currentFTP, monument: own ?? fallback,
                                monumentIs90d: own == nil && fallback != nil)
        guard period != .days42 else { return t }
        let from = startDay(period, curve: curves[period.curve], today: today)
        if let peak = RideThreshold.peak(rides, from: from), let f = peak.ftp, f > (currentFTP ?? 0) {
            t.intervalsFTP = f
            t.intervalsFTPRide = peak
        }
        return t
    }

    /// The weight to divide an effort by: the weight on the ride that set it, else `fallback`.
    public static func weight(for effort: RiderEffort?, rideWeights: [String: Double], fallback: Double?) -> Double? {
        effort?.activity.flatMap { rideWeights[$0] } ?? fallback
    }
}
