import Foundation

// Models for the parts of the Intervals.icu API that v2 reads. Field names match the raw
// API (snake_case and icu_ prefixes); everything except `id` is optional because what comes
// back depends on the activity type and which sensors were recorded.

/// Intervals sends ids as strings ("i196049903") but some sources use plain numbers.
public struct FlexibleID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let value: String
    public init(_ value: String) { self.value = value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            value = s
        } else if let i = try? c.decode(Int64.self) {
            value = String(i)
        } else {
            value = String(try c.decode(Double.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }

    public var description: String { value }
}

/// One row of /athlete/{id}/activities, also the top level of /activity/{id}.
public struct ActivitySummary: Decodable, Identifiable, Hashable, Sendable {
    public let id: FlexibleID
    public let startDateLocal: String?
    public let type: String?
    public let name: String?
    public let description: String?
    public let source: String?
    /// Seconds.
    public let movingTime: Double?
    public let elapsedTime: Double?
    /// Metres.
    public let distance: Double?
    public let totalElevationGain: Double?
    public let trainingLoad: Double?
    /// Intensity as a percentage of FTP (Intervals' "IF" × 100).
    public let intensity: Double?
    public let normalizedPower: Double?
    public let averagePower: Double?
    public let averageHeartRate: Double?
    public let maxHeartRate: Double?
    public let averageCadence: Double?
    public let averageSpeed: Double?
    public let ftp: Double?
    public let weight: Double?
    public let decoupling: Double?
    /// 1–10.
    public let rpe: Int?
    /// Intervals' scale: 1 strong … 5 weak.
    public let feel: Int?
    public let pairedEventId: FlexibleID?

    enum CodingKeys: String, CodingKey {
        case id, type, name, description, source, distance, feel, decoupling
        case startDateLocal = "start_date_local"
        case movingTime = "moving_time"
        case elapsedTime = "elapsed_time"
        case totalElevationGain = "total_elevation_gain"
        case trainingLoad = "icu_training_load"
        case intensity = "icu_intensity"
        case normalizedPower = "icu_weighted_avg_watts"
        case averagePower = "icu_average_watts"
        case averageHeartRate = "average_heartrate"
        case maxHeartRate = "max_heartrate"
        case averageCadence = "average_cadence"
        case averageSpeed = "average_speed"
        case ftp = "icu_ftp"
        case weight = "icu_weight"
        case rpe = "icu_rpe"
        case pairedEventId = "paired_event_id"
    }

    /// Activities recorded in the Strava app come back as empty stubs: Strava won't let
    /// Intervals share them through the API.
    public var isStravaPlaceholder: Bool {
        source == "STRAVA" && (movingTime ?? 0) == 0 && name == nil
    }

    /// Logged once the athlete has given it an RPE.
    public var isLogged: Bool { rpe != nil }

    public var startDate: Date? { startDateLocal.flatMap(IntervalsDates.parseLocal) }
}

/// A lap or detected interval from /activity/{id}?intervals=true (`icu_intervals`).
public struct ActivityInterval: Decodable, Hashable, Sendable {
    public let id: Int?
    public let label: String?
    /// WORK or RECOVERY.
    public let type: String?
    /// Indexes into the activity's streams (end is inclusive in Intervals).
    public let startIndex: Int?
    public let endIndex: Int?
    /// Seconds from the start of the activity.
    public let startTime: Double?
    public let endTime: Double?
    public let movingTime: Double?
    public let elapsedTime: Double?
    public let distance: Double?
    public let averagePower: Double?
    public let normalizedPower: Double?
    public let maxPower: Double?
    public let averageHeartRate: Double?
    public let maxHeartRate: Double?
    public let averageCadence: Double?
    public let averageSpeed: Double?
    public let trainingLoad: Double?
    public let intensity: Double?
    public let decoupling: Double?
    public let zone: Int?
    /// Joules.
    public let wbalStart: Double?
    public let wbalEnd: Double?

    enum CodingKeys: String, CodingKey {
        case id, label, type, distance, intensity, decoupling, zone
        case startIndex = "start_index"
        case endIndex = "end_index"
        case startTime = "start_time"
        case endTime = "end_time"
        case movingTime = "moving_time"
        case elapsedTime = "elapsed_time"
        case averagePower = "average_watts"
        case normalizedPower = "weighted_average_watts"
        case maxPower = "max_watts"
        case averageHeartRate = "average_heartrate"
        case maxHeartRate = "max_heartrate"
        case averageCadence = "average_cadence"
        case averageSpeed = "average_speed"
        case trainingLoad = "training_load"
        case wbalStart = "wbal_start"
        case wbalEnd = "wbal_end"
    }

    public var isWork: Bool { (type ?? "WORK").uppercased() == "WORK" }
}

/// /activity/{id}?intervals=true: the summary plus laps/intervals and a few extras.
public struct ActivityDetail: Decodable, Sendable {
    public let summary: ActivitySummary
    public let intervals: [ActivityInterval]
    /// Streams recorded for this activity (w_bal isn't listed but can still be requested).
    public let streamTypes: [String]
    /// Joules.
    public let maxWbalDepletion: Double?
    public let joulesAboveFTP: Double?

    enum CodingKeys: String, CodingKey {
        case intervals = "icu_intervals"
        case streamTypes = "stream_types"
        case maxWbalDepletion = "icu_max_wbal_depletion"
        case joulesAboveFTP = "icu_joules_above_ftp"
    }

    public init(from decoder: Decoder) throws {
        summary = try ActivitySummary(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intervals = (try c.decodeIfPresent([ActivityInterval?].self, forKey: .intervals) ?? []).compactMap { $0 }
        streamTypes = try c.decodeIfPresent([String].self, forKey: .streamTypes) ?? []
        maxWbalDepletion = try c.decodeIfPresent(Double.self, forKey: .maxWbalDepletion)
        joulesAboveFTP = try c.decodeIfPresent(Double.self, forKey: .joulesAboveFTP)
    }
}

/// Stream names v2 asks for.
public enum StreamType: String, CaseIterable, Sendable {
    case time, watts, heartrate, cadence, distance, altitude, temp
    case velocity = "velocity_smooth"
    case wbal = "w_bal"
    /// Some power sources come back under this name instead of `watts`.
    case fixedWatts = "fixed_watts"

    /// What the activity view requests.
    public static let activityView: [StreamType] = [
        .time, .watts, .heartrate, .cadence, .velocity, .altitude, .distance, .wbal, .temp
    ]
}

/// Second-by-second data from /activity/{id}/streams.json, aligned by index.
public struct ActivityStreams: Sendable {
    /// Seconds from the start for each sample. Not always contiguous: pauses leave gaps.
    public let time: [Double]
    public let series: [StreamType: [Double?]]

    public init(time: [Double], series: [StreamType: [Double?]]) {
        self.time = time
        self.series = series
    }

    public subscript(_ type: StreamType) -> [Double?]? { series[type] }

    /// True if the stream exists and has at least one real value.
    public func has(_ type: StreamType) -> Bool {
        series[type]?.contains { $0 != nil } ?? false
    }

    public var count: Int { time.count }

    /// Decodes the API's `[{"type": "...", "data": [...]}, ...]` shape. Unknown stream types
    /// are skipped, `fixed_watts` stands in for missing `watts`, and short streams are padded.
    public static func decode(_ data: Data) throws -> ActivityStreams {
        struct Raw: Decodable {
            let type: String
            let data: [Double?]?

            enum CodingKeys: String, CodingKey { case type, data }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                type = try c.decode(String.self, forKey: .type)
                // latlng and similar come back as nested arrays; those aren't charted.
                data = try? c.decodeIfPresent([Double?].self, forKey: .data)
            }
        }

        let raw = try JSONDecoder().decode([Raw].self, from: data)
        var series: [StreamType: [Double?]] = [:]
        for r in raw {
            guard let type = StreamType(rawValue: r.type), let values = r.data else { continue }
            series[type] = values
        }
        if series[.watts] == nil, let fixed = series[.fixedWatts] {
            series[.watts] = fixed
        }
        series[.fixedWatts] = nil

        let time: [Double]
        if let t = series.removeValue(forKey: .time) {
            // Time can't be missing mid-stream; carry the last value forward if it is.
            var last = 0.0
            time = t.map { v in
                if let v { last = v }
                return last
            }
        } else {
            let n = series.values.map(\.count).max() ?? 0
            time = (0..<n).map(Double.init)
        }

        for (key, values) in series where values.count != time.count {
            series[key] = values.count > time.count
                ? Array(values.prefix(time.count))
                : values + Array(repeating: nil, count: time.count - values.count)
        }
        return ActivityStreams(time: time, series: series)
    }
}

/// What the quick log sends back. Each field is left out of the request when nil.
public struct ActivityLog: Equatable, Sendable {
    public var rpe: Int?
    public var feel: Int?
    public var description: String?

    public init(rpe: Int? = nil, feel: Int? = nil, description: String? = nil) {
        self.rpe = rpe
        self.feel = feel
        self.description = description
    }

    /// JSON body for PUT /activity/{id}.
    public var body: [String: Any] {
        var b: [String: Any] = [:]
        if let rpe { b["icu_rpe"] = min(max(rpe, 1), 10) }
        if let feel { b["feel"] = min(max(feel, 1), 5) }
        if let description { b["description"] = description }
        return b
    }

    /// Adds a one-line note to the end of existing notes without losing them.
    public static func appending(note: String, to existing: String?) -> String? {
        let line = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        let old = (existing ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return old.isEmpty ? line : old + "\n" + line
    }
}

/// Optional wellness fields for PUT /athlete/{id}/wellness/{date}.
public struct WellnessLog: Equatable, Sendable {
    public var sleepHours: Double?
    /// Intervals' scale: 1 low … 4 extreme.
    public var soreness: Int?
    public var weightKg: Double?

    public init(sleepHours: Double? = nil, soreness: Int? = nil, weightKg: Double? = nil) {
        self.sleepHours = sleepHours
        self.soreness = soreness
        self.weightKg = weightKg
    }

    public var isEmpty: Bool { sleepHours == nil && soreness == nil && weightKg == nil }

    public var body: [String: Any] {
        var b: [String: Any] = [:]
        if let sleepHours { b["sleepSecs"] = Int((sleepHours * 3600).rounded()) }
        if let soreness { b["soreness"] = min(max(soreness, 1), 4) }
        if let weightKg { b["weight"] = weightKg }
        return b
    }
}

public enum IntervalsDates {
    /// Parses "2026-10-11T08:09:20" as a local wall-clock time.
    public static func parseLocal(_ s: String) -> Date? {
        localFormatter.date(from: String(s.prefix(19)))
    }

    public static func day(_ date: Date) -> String { dayFormatter.string(from: date) }

    private static let localFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

public enum LogPrompt {
    /// The newest recent activity that has no RPE yet and hasn't been dismissed, if any.
    /// Strava stubs are skipped because they can't be edited through the API.
    public static func unlogged(in activities: [ActivitySummary], now: Date = Date(),
                                within window: TimeInterval = 3 * 24 * 3600,
                                dismissed: Set<String> = []) -> ActivitySummary? {
        activities
            .filter { !$0.isStravaPlaceholder && !$0.isLogged && !dismissed.contains($0.id.value) }
            .filter { a in
                guard let start = a.startDate else { return false }
                return now.timeIntervalSince(start) <= window && start <= now
            }
            .max { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
    }
}
