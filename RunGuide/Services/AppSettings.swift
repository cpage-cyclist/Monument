import Foundation
import RunGuideCore

final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var athleteId: String {
        didSet { defaults.set(athleteId.trimmingCharacters(in: .whitespaces), forKey: "athleteId") }
    }
    /// Stored in the Keychain, never in the code or the repo.
    @Published var apiKey: String {
        didSet { Keychain.set(apiKey.trimmingCharacters(in: .whitespaces), for: "intervalsApiKey") }
    }
    @Published var lapPaceFeedback: Bool {
        didSet { defaults.set(lapPaceFeedback, forKey: "lapPaceFeedback") }
    }
    @Published var kmSplits: Bool {
        didSet { defaults.set(kmSplits, forKey: "kmSplits") }
    }
    @Published var autoUpload: Bool {
        didSet { defaults.set(autoUpload, forKey: "autoUpload") }
    }
    @Published var uploadToStrava: Bool {
        didSet { defaults.set(uploadToStrava, forKey: "uploadToStrava") }
    }
    /// Empty means "automatic: best UK voice".
    @Published var voiceIdentifier: String {
        didSet { defaults.set(voiceIdentifier, forKey: Announcer.voiceKey) }
    }

    init() {
        athleteId = defaults.string(forKey: "athleteId") ?? ""
        apiKey = Keychain.get("intervalsApiKey") ?? ""
        lapPaceFeedback = defaults.object(forKey: "lapPaceFeedback") as? Bool ?? true
        kmSplits = defaults.object(forKey: "kmSplits") as? Bool ?? true
        autoUpload = defaults.object(forKey: "autoUpload") as? Bool ?? true
        uploadToStrava = defaults.object(forKey: "uploadToStrava") as? Bool ?? true
        voiceIdentifier = defaults.string(forKey: Announcer.voiceKey) ?? ""
    }

    var hasCredentials: Bool {
        !athleteId.trimmingCharacters(in: .whitespaces).isEmpty && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var client: IntervalsClient {
        IntervalsClient(athleteId: athleteId.trimmingCharacters(in: .whitespaces),
                        apiKey: apiKey.trimmingCharacters(in: .whitespaces))
    }

    var engineOptions: EngineOptions {
        EngineOptions(lapPaceFeedback: lapPaceFeedback, kmSplits: kmSplits)
    }
}
