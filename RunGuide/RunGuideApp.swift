import SwiftUI

@main
struct RunGuideApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var heartRate = HeartRateMonitor()
    @StateObject private var store = RunStore()
    @StateObject private var routes = RouteStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(settings)
                .environmentObject(heartRate)
                .environmentObject(store)
                .environmentObject(routes)
                .onOpenURL { url in routes.importRoute(from: url) }
        }
    }
}
