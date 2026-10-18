import AuthenticationServices
import SwiftUI
import Foundation
import UIKit

/// A route as Strava lists it.
struct StravaRoute: Identifiable, Hashable, Decodable {
    let idStr: String
    let name: String
    let distance: Double
    let type: Int?
    let isPrivate: Bool?

    var id: String { idStr }
    var isRun: Bool { type == 2 }

    enum CodingKeys: String, CodingKey {
        case idStr = "id_str", name, distance, type, isPrivate = "private"
    }
}

enum StravaError: LocalizedError {
    case missingApp
    case notConnected
    case denied
    case missingPrivateScope
    case missingUploadScope
    case uploadFailed(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingApp: return "Add your Strava Client ID and Client Secret in Settings first."
        case .notConnected: return "Connect Strava in Settings first."
        case .denied: return "Strava access wasn't granted."
        case .missingPrivateScope: return "Connected, but without access to private routes. Reconnect and leave \"View data about your private activities\" ticked to see them."
        case .missingUploadScope: return "Strava isn't allowing uploads yet. In Settings tap Reconnect and leave \"Upload your activities\" ticked."
        case .uploadFailed(let message): return "Strava couldn't process the run: \(message)"
        case .http(let code, let body):
            if code == 401 { return "Strava rejected the sign-in. Try Disconnect, then Connect again." }
            return "Strava returned an error (\(code)). \(body.prefix(160))"
        }
    }
}

/// Your Strava connection: OAuth sign-in, token refresh, listing and
/// downloading routes. Uses your own Strava API app (Client ID/Secret),
/// stored in the Keychain.
@MainActor
final class StravaAccount: ObservableObject {
    /// Must match the "Authorization Callback Domain" (localhost) in the Strava API app.
    static let redirectURI = "runguide://localhost"
    static let callbackScheme = "runguide"

    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespaces), forKey: "stravaClientID") }
    }
    @Published var clientSecret: String {
        didSet { Keychain.set(clientSecret.trimmingCharacters(in: .whitespaces), for: "stravaClientSecret") }
    }
    @Published private(set) var athleteName: String?
    @Published private(set) var hasPrivateAccess = false
    @Published private(set) var hasUploadAccess = false
    @Published private(set) var connecting = false
    @Published var lastError: String?

    private struct Tokens: Codable {
        var access: String
        var refresh: String
        var expiresAt: Double
        var athleteID: Int
        var athleteName: String?
        var scope: String
    }

    private var tokens: Tokens? {
        didSet {
            if let tokens, let data = try? JSONEncoder().encode(tokens) {
                Keychain.set(String(decoding: data, as: UTF8.self), for: "stravaTokens")
            } else {
                Keychain.set("", for: "stravaTokens")
            }
            athleteName = tokens?.athleteName
            hasPrivateAccess = tokens?.scope.contains("read_all") ?? false
            hasUploadAccess = tokens?.scope.contains("activity:write") ?? false
        }
    }
    private var pendingState: String?

    init() {
        clientID = UserDefaults.standard.string(forKey: "stravaClientID") ?? ""
        clientSecret = Keychain.get("stravaClientSecret") ?? ""
        if let json = Keychain.get("stravaTokens"), let t = try? JSONDecoder().decode(Tokens.self, from: Data(json.utf8)) {
            tokens = t
            athleteName = t.athleteName
            hasPrivateAccess = t.scope.contains("read_all")
            hasUploadAccess = t.scope.contains("activity:write")
        }
    }

    var hasAppDetails: Bool {
        !clientID.trimmingCharacters(in: .whitespaces).isEmpty && !clientSecret.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var isConnected: Bool { tokens != nil }

    // MARK: - Connecting

    private func authorizeURL(base: String) -> URL? {
        let state = UUID().uuidString
        pendingState = state
        var c = URLComponents(string: base)
        c?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID.trimmingCharacters(in: .whitespaces)),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "approval_prompt", value: "auto"),
            URLQueryItem(name: "scope", value: "read,read_all,activity:write"),
            URLQueryItem(name: "state", value: state)
        ]
        return c?.url
    }

    /// Opens the Strava app to approve if it's installed (it calls back via
    /// runguide://), otherwise a secure web sign-in sheet.
    func connect(using webAuth: WebAuthenticationSession) async {
        lastError = nil
        guard hasAppDetails else { lastError = StravaError.missingApp.errorDescription; return }

        if let appURL = authorizeURL(base: "strava://oauth/mobile/authorize"),
           UIApplication.shared.canOpenURL(appURL) {
            connecting = true
            await UIApplication.shared.open(appURL)
            return   // finishes in handleCallback(_:)
        }

        guard let webURL = authorizeURL(base: "https://www.strava.com/oauth/mobile/authorize") else { return }
        connecting = true
        do {
            let callback = try await webAuth.authenticate(using: webURL, callbackURLScheme: Self.callbackScheme)
            await handleCallback(callback)
        } catch {
            connecting = false
            if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                lastError = error.localizedDescription
            }
        }
    }

    /// True if this URL is a Strava sign-in callback (rather than a route file).
    static func isCallback(_ url: URL) -> Bool { url.scheme == callbackScheme }

    func handleCallback(_ url: URL) async {
        defer { connecting = false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if value("error") != nil { lastError = StravaError.denied.errorDescription; return }
        guard let code = value("code") else { return }
        if let expected = pendingState, let got = value("state"), expected != got { return }
        pendingState = nil

        do {
            let json = try await tokenRequest([
                "grant_type": "authorization_code",
                "code": code
            ])
            let athlete = json["athlete"] as? [String: Any]
            let first = athlete?["firstname"] as? String
            let last = athlete?["lastname"] as? String
            tokens = Tokens(
                access: json["access_token"] as? String ?? "",
                refresh: json["refresh_token"] as? String ?? "",
                expiresAt: (json["expires_at"] as? Double) ?? Double(json["expires_at"] as? Int ?? 0),
                athleteID: athlete?["id"] as? Int ?? 0,
                athleteName: [first, last].compactMap { $0 }.joined(separator: " "),
                scope: value("scope") ?? ""
            )
            if !hasPrivateAccess {
                lastError = StravaError.missingPrivateScope.errorDescription
            } else if !hasUploadAccess {
                lastError = StravaError.missingUploadScope.errorDescription
            } else {
                lastError = nil
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func disconnect() {
        if let access = tokens?.access {
            // Revoke on Strava's side too (best effort).
            var request = URLRequest(url: URL(string: "https://www.strava.com/oauth/deauthorize")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: request).resume()
        }
        tokens = nil
    }

    // MARK: - API

    func routes() async throws -> [StravaRoute] {
        let t = try await validTokens()
        var all: [StravaRoute] = []
        for page in 1...10 {
            let data = try await get("athletes/\(t.athleteID)/routes?page=\(page)&per_page=100", token: t.access)
            let batch = try JSONDecoder().decode([StravaRoute].self, from: data)
            all += batch
            if batch.count < 100 { break }
        }
        return all
    }

    func gpx(for route: StravaRoute) async throws -> Data {
        let t = try await validTokens()
        return try await get("routes/\(route.idStr)/export_gpx", token: t.access)
    }

    /// Uploads a FIT file as a new Strava activity and waits for Strava to
    /// process it. Returns the activity id. A run already on Strava (same
    /// file or same external id) counts as success.
    func uploadActivity(fileURL: URL, name: String, description: String, externalID: String) async throws -> String? {
        guard hasUploadAccess else { throw StravaError.missingUploadScope }
        let t = try await validTokens()

        let boundary = "RunGuide-\(UUID().uuidString)"
        var body = Data()
        func field(_ key: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("data_type", "fit")
        field("name", name)
        field("description", description)
        field("external_id", externalID)
        field("sport_type", "Run")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(try Data(contentsOf: fileURL))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: "https://www.strava.com/api/v3/uploads")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(t.access)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        try check(response, data)

        // Strava processes uploads in the background; poll until done.
        var status = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        for _ in 0..<15 {
            if let result = try Self.uploadResult(status) { return result }
            try await Task.sleep(nanoseconds: 2_000_000_000)
            guard let uploadID = status["id_str"] as? String ?? (status["id"] as? Int).map(String.init) else { break }
            let poll = try await get("uploads/\(uploadID)", token: t.access)
            status = try JSONSerialization.jsonObject(with: poll) as? [String: Any] ?? [:]
        }
        if let result = try Self.uploadResult(status) { return result }
        return nil   // still processing; it will appear on Strava shortly
    }

    /// nil = still processing; a value = done (activity id, or "" if unknown).
    private static func uploadResult(_ status: [String: Any]) throws -> String?? {
        if let error = status["error"] as? String, !error.isEmpty {
            // e.g. "… duplicate of <a href='/activities/123'>…</a>"
            if error.lowercased().contains("duplicate") { return .some(nil) }
            throw StravaError.uploadFailed(error.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
        }
        if let id = status["activity_id"] as? Int { return .some(String(id)) }
        if let id = status["activity_id"] as? String, !id.isEmpty { return .some(id) }
        return nil
    }

    // MARK: - Plumbing

    private func validTokens() async throws -> Tokens {
        guard let t = tokens else { throw StravaError.notConnected }
        // Refresh if it expires within 5 minutes (tokens last 6 hours).
        if t.expiresAt > Date().timeIntervalSince1970 + 300 { return t }
        let json = try await tokenRequest(["grant_type": "refresh_token", "refresh_token": t.refresh])
        var updated = t
        updated.access = json["access_token"] as? String ?? t.access
        updated.refresh = json["refresh_token"] as? String ?? t.refresh   // always keep the newest
        updated.expiresAt = (json["expires_at"] as? Double) ?? Double(json["expires_at"] as? Int ?? 0)
        tokens = updated
        return updated
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> [String: Any] {
        var all = fields
        all["client_id"] = clientID.trimmingCharacters(in: .whitespaces)
        all["client_secret"] = clientSecret.trimmingCharacters(in: .whitespaces)
        var request = URLRequest(url: URL(string: "https://www.strava.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = all.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((body.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StravaError.http(0, "Unexpected response")
        }
        return json
    }

    private func get(_ path: String, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://www.strava.com/api/v3/\(path)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        return data
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if !(200..<300).contains(http.statusCode) {
            throw StravaError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
    }
}
