import Foundation
import RunGuideCore

struct IntervalsEvent: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let description: String?
    let type: String?
    let category: String?
    let start_date_local: String?
}

enum IntervalsError: LocalizedError {
    case missingCredentials
    case badCredentials
    case notFound
    case rateLimited
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "Add your Intervals athlete ID and API key in Settings."
        case .badCredentials: return "Intervals rejected the athlete ID or API key. Check them in Settings."
        case .notFound: return "Intervals couldn't find that activity."
        case .rateLimited: return "Intervals is busy. Try again in a moment."
        case .http(let code): return "Intervals returned an error (\(code)). Try again in a moment."
        }
    }
}

/// Talks to the Intervals.icu API.
/// Auth is HTTP Basic with username "API_KEY" and your key as the password.
struct IntervalsClient {
    let athleteId: String
    let apiKey: String

    private static let base = "https://intervals.icu/api/v1"

    /// Fields the activity list asks for, so the response stays small.
    static let activityListFields = [
        "id", "start_date_local", "type", "name", "description", "source", "moving_time",
        "elapsed_time", "distance", "total_elevation_gain", "icu_training_load", "icu_intensity",
        "icu_weighted_avg_watts", "icu_average_watts", "average_heartrate", "max_heartrate",
        "average_cadence", "average_speed", "icu_ftp", "icu_weight", "decoupling", "icu_rpe",
        "feel", "paired_event_id", "carbs_ingested"
    ]

    // MARK: - Planned runs (v1)

    func plannedRuns(on date: Date) async throws -> [IntervalsEvent] {
        let day = IntervalsDates.day(date)
        let data = try await send("GET", "/athlete/\(athleteId)/events",
                                  query: ["oldest": day, "newest": day])
        let events = try JSONDecoder().decode([IntervalsEvent].self, from: data)
        return events.filter { event in
            (event.category ?? "WORKOUT") == "WORKOUT"
                && (event.type ?? "Run").lowercased().contains("run")
                && !(event.description ?? "").isEmpty
        }
    }

    // MARK: - Activities (v2)

    /// Raw JSON for activities between two days, newest first. Raw so it can be cached as-is.
    func activitiesData(oldest: Date, newest: Date, limit: Int = 100) async throws -> Data {
        try await activitiesData(oldest: IntervalsDates.day(oldest), newest: IntervalsDates.day(newest), limit: limit)
    }

    func activitiesData(oldest: String, newest: String, limit: Int = 100) async throws -> Data {
        try await send("GET", "/athlete/\(athleteId)/activities", query: [
            "oldest": oldest,
            "newest": newest,
            "limit": String(limit),
            "fields": Self.activityListFields.joined(separator: ",")
        ])
    }

    /// Raw JSON for one activity including its laps/intervals.
    func activityData(id: String) async throws -> Data {
        try await send("GET", "/activity/\(Self.escape(id))", query: ["intervals": "true"])
    }

    /// Raw JSON for an activity's streams.
    func streamsData(id: String, types: [StreamType] = StreamType.activityView) async throws -> Data {
        var names = types.map(\.rawValue)
        if names.contains(StreamType.watts.rawValue) { names.append(StreamType.fixedWatts.rawValue) }
        return try await send("GET", "/activity/\(Self.escape(id))/streams.json",
                              query: ["types": names.joined(separator: ",")])
    }

    /// Sets RPE, feel and/or notes on an activity. Returns the updated activity's JSON.
    @discardableResult
    func updateActivity(id: String, log: ActivityLog) async throws -> Data {
        let body = log.body
        guard !body.isEmpty else { return Data() }
        return try await send("PUT", "/activity/\(Self.escape(id))",
                              json: try JSONSerialization.data(withJSONObject: body))
    }

    /// Records wellness fields for a day.
    func logWellness(_ wellness: WellnessLog, on date: Date) async throws {
        guard !wellness.isEmpty else { return }
        _ = try await send("PUT", "/athlete/\(athleteId)/wellness/\(IntervalsDates.day(date))",
                           json: try JSONSerialization.data(withJSONObject: wellness.body))
    }

    /// Raw JSON for the best-power curve between two days (inclusive) for a sport.
    func powerCurveData(type: String, from: String, to: String) async throws -> Data {
        try await send("GET", "/athlete/\(athleteId)/power-curves.json",
                       query: ["type": type, "curves": "r.\(from).\(to)"])
    }

    /// Year and all-time best power with the 2nd and 3rd best efforts at each duration
    /// (and the activities they came from), for medalling peaks.
    func powerCurveRanksData(type: String) async throws -> Data {
        try await send("GET", "/athlete/\(athleteId)/power-curves.json",
                       query: ["type": type, "curves": "1y,all", "subMaxEfforts": "2"])
    }

    // MARK: - Calendar and fitness (v2)

    /// Raw JSON for calendar entries (planned workouts, races, notes) between two days.
    func eventsData(oldest: String, newest: String) async throws -> Data {
        try await send("GET", "/athlete/\(athleteId)/events", query: ["oldest": oldest, "newest": newest])
    }

    /// Raw JSON for daily fitness/wellness between two days.
    func wellnessData(oldest: String, newest: String) async throws -> Data {
        try await send("GET", "/athlete/\(athleteId)/wellness", query: ["oldest": oldest, "newest": newest])
    }

    /// Moves a calendar entry to another day.
    func moveEvent(id: Int, to day: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["start_date_local": day + "T00:00:00"])
        _ = try await send("PUT", "/athlete/\(athleteId)/events/\(id)", json: body)
    }

    /// Removes a calendar entry. Completed activities aren't affected.
    func deleteEvent(id: Int) async throws {
        _ = try await send("DELETE", "/athlete/\(athleteId)/events/\(id)")
    }

    /// Adds a note to a day's calendar.
    func addNote(on day: String, title: String, text: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "category": "NOTE",
            "start_date_local": day + "T00:00:00",
            "name": title,
            "description": text
        ])
        _ = try await send("POST", "/athlete/\(athleteId)/events", json: body)
    }

    // MARK: - Workouts (builder)

    /// Raw JSON for the library: folders and plans with their workouts.
    func foldersData() async throws -> Data {
        try await send("GET", "/athlete/\(athleteId)/folders")
    }

    /// One library workout with its full step text.
    func libraryWorkout(id: Int) async throws -> LibraryWorkout {
        let data = try await send("GET", "/athlete/\(athleteId)/workouts/\(id)")
        return try JSONDecoder().decode(LibraryWorkout.self, from: data)
    }

    /// Adds a workout to a day's calendar. Returns the entry as Intervals parsed it (load, time).
    func createWorkoutEvent(_ plan: WorkoutPlan, on day: String) async throws -> CalendarEvent {
        var fields = plan.intervalsFields()
        fields["category"] = "WORKOUT"
        fields["start_date_local"] = day + "T00:00:00"
        let data = try await send("POST", "/athlete/\(athleteId)/events",
                                  json: try JSONSerialization.data(withJSONObject: fields))
        return try JSONDecoder().decode(CalendarEvent.self, from: data)
    }

    /// Rewrites a planned workout's name, sport and steps.
    func updateWorkoutEvent(id: Int, _ plan: WorkoutPlan) async throws -> CalendarEvent {
        let data = try await send("PUT", "/athlete/\(athleteId)/events/\(id)",
                                  json: try JSONSerialization.data(withJSONObject: plan.intervalsFields()))
        return try JSONDecoder().decode(CalendarEvent.self, from: data)
    }

    /// Saves a new workout into a library folder.
    func createLibraryWorkout(_ plan: WorkoutPlan, folderId: Int) async throws -> LibraryWorkout {
        var fields = plan.intervalsFields()
        fields["folder_id"] = folderId
        let data = try await send("POST", "/athlete/\(athleteId)/workouts",
                                  json: try JSONSerialization.data(withJSONObject: fields))
        return try JSONDecoder().decode(LibraryWorkout.self, from: data)
    }

    /// Rewrites a library workout.
    func updateLibraryWorkout(id: Int, _ plan: WorkoutPlan) async throws -> LibraryWorkout {
        let data = try await send("PUT", "/athlete/\(athleteId)/workouts/\(id)",
                                  json: try JSONSerialization.data(withJSONObject: plan.intervalsFields()))
        return try JSONDecoder().decode(LibraryWorkout.self, from: data)
    }

    // MARK: - Upload (v1)

    /// Uploads a FIT file as a new activity. Returns the new activity's id if Intervals sends one back.
    func uploadActivity(fileURL: URL, name: String, description: String) async throws -> String? {
        let boundary = "RunGuide-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(try Data(contentsOf: fileURL))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let data = try await send("POST", "/athlete/\(athleteId)/activities",
                                  query: ["name": name, "description": description],
                                  body: body,
                                  contentType: "multipart/form-data; boundary=\(boundary)",
                                  timeout: 60)
        return Self.activityId(in: data)
    }

    /// Pulls an activity id out of the upload response, whatever shape it takes.
    static func activityId(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let object = json as? [String: Any] {
            if let id = object["id"] as? String { return id }
            if let id = object["id"] as? Int { return String(id) }
            if let list = object["activities"] as? [[String: Any]], let id = list.first?["id"] {
                return "\(id)"
            }
        }
        if let list = json as? [[String: Any]], let id = list.first?["id"] {
            return "\(id)"
        }
        return nil
    }

    // MARK: - Plumbing

    private func send(_ method: String, _ path: String, query: [String: String] = [:],
                      json: Data? = nil, body: Data? = nil, contentType: String? = nil,
                      timeout: TimeInterval = 20) async throws -> Data {
        guard !athleteId.isEmpty, !apiKey.isEmpty else { throw IntervalsError.missingCredentials }

        var components = URLComponents(string: Self.base + path)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        let token = Data("API_KEY:\(apiKey)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout

        let payload = json ?? body
        if json != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        let (data, response): (Data, URLResponse)
        if let payload {
            (data, response) = try await URLSession.shared.upload(for: request, from: payload)
        } else {
            (data, response) = try await URLSession.shared.data(for: request)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 401, 403: throw IntervalsError.badCredentials
            case 404: throw IntervalsError.notFound
            case 429: throw IntervalsError.rateLimited
            default: throw IntervalsError.http(http.statusCode)
            }
        }
        return data
    }

    private static func escape(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
    }
}
