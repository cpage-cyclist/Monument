import SwiftUI

@main
struct RunGuideApp: App {
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(settings)
        }
    }
}
