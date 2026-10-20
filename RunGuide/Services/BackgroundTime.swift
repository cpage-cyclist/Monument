import UIKit

/// Asks iOS for extra time to finish work (like an upload) if the app goes into the
/// background, e.g. the phone is locked straight after tapping Save. Without it iOS
/// suspends the app within seconds and the upload stalls until the app is next opened.
@MainActor
enum BackgroundTime {
    private final class Token: @unchecked Sendable {
        var id: UIBackgroundTaskIdentifier = .invalid
    }

    static func run<T>(_ name: String, _ work: () async throws -> T) async rethrows -> T {
        let token = Token()
        token.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            // Out of time: let iOS suspend us rather than be killed.
            UIApplication.shared.endBackgroundTask(token.id)
            token.id = .invalid
        }
        defer {
            if token.id != .invalid {
                UIApplication.shared.endBackgroundTask(token.id)
                token.id = .invalid
            }
        }
        return try await work()
    }
}
