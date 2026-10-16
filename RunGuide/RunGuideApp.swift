import SwiftUI

@main
struct RunGuideApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var heartRate = HeartRateMonitor()
    @StateObject private var store = RunStore()
    @StateObject private var routes = RouteStore()
    @StateObject private var strava = StravaAccount()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(settings)
                .environmentObject(heartRate)
                .environmentObject(store)
                .environmentObject(routes)
                .environmentObject(strava)
                .onOpenURL { url in
                    if StravaAccount.isCallback(url) {
                        Task { await strava.handleCallback(url) }
                    } else {
                        routes.importRoute(from: url)
                    }
                }
        }
    }
}
