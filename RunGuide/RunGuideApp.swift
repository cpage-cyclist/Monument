import SwiftUI

@main
struct RunGuideApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var heartRate = HeartRateMonitor()
    @StateObject private var store = RunStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(settings)
                .environmentObject(heartRate)
                .environmentObject(store)
        }
    }
}
