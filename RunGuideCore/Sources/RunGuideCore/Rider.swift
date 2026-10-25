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
