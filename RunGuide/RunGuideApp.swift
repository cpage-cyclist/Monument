import SwiftUI

@main
struct RunGuideApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var heartRate = HeartRateMonitor()
    @StateObject private var store = RunStore()
    @StateObject private var routes = RouteStore()
    @StateObject private var strava = StravaAccount()
    @StateObject private var library = ActivityLibrary()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(heartRate)
                .environmentObject(store)
                .environmentObject(routes)
                .environmentObject(strava)
                .environmentObject(library)
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

/// Tabs: activities from Intervals, and the Run Guide run player.
struct RootView: View {
    var body: some View {
        TabView {
            ActivitiesView()
                .tabItem { Label("Activities", systemImage: "chart.xyaxis.line") }
            HomeView()
                .tabItem { Label("Run", systemImage: "figure.run") }
        }
    }
}
