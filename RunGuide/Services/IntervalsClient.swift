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

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
