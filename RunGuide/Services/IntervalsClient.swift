import Foundation

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
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "Add your Intervals athlete ID and API key in Settings."
        case .badCredentials: return "Intervals rejected the athlete ID or API key. Check them in Settings."
        case .http(let code): return "Intervals returned an error (\(code)). Try again in a moment."
        }
    }
}

/// Reads planned workouts from the Intervals.icu API.
/// Auth is HTTP Basic with username "API_KEY" and your key as the password.
struct IntervalsClient {
    let athleteId: String
    let apiKey: String

    func plannedRuns(on date: Date) async throws -> [IntervalsEvent] {
        guard !athleteId.isEmpty, !apiKey.isEmpty else { throw IntervalsError.missingCredentials }

        let day = Self.dayFormatter.string(from: date)
        var components = URLComponents(string: "https://intervals.icu/api/v1/athlete/\(athleteId)/events")!
        components.queryItems = [
            URLQueryItem(name: "oldest", value: day),
            URLQueryItem(name: "newest", value: day)
        ]

        var request = URLRequest(url: components.url!)
        let token = Data("API_KEY:\(apiKey)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw IntervalsError.badCredentials }
            if !(200..<300).contains(http.statusCode) { throw IntervalsError.http(http.statusCode) }
        }

        let events = try JSONDecoder().decode([IntervalsEvent].self, from: data)
        return events.filter { event in
            (event.category ?? "WORKOUT") == "WORKOUT"
                && (event.type ?? "Run").lowercased().contains("run")
                && !(event.description ?? "").isEmpty
        }
    }

    /// Uploads a FIT file as a new activity. Returns the new activity's id if Intervals sends one back.
    func uploadActivity(fileURL: URL, name: String, description: String) async throws -> String? {
        guard !athleteId.isEmpty, !apiKey.isEmpty else { throw IntervalsError.missingCredentials }

        var components = URLComponents(string: "https://intervals.icu/api/v1/athlete/\(athleteId)/activities")!
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "description", value: description)
        ]

        let boundary = "RunGuide-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(try Data(contentsOf: fileURL))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        let token = Data("API_KEY:\(apiKey)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw IntervalsError.badCredentials }
            if !(200..<300).contains(http.statusCode) { throw IntervalsError.http(http.statusCode) }
        }
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

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
