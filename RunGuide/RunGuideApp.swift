import SwiftUI

@main
struct RunGuideApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var heartRate = HeartRateMonitor()
    @StateObject private var store = RunStore()
    @StateObject private var routes = RouteStore()
    @StateObject private var strava = StravaAccount()
    @StateObject private var library = ActivityLibrary()
    @StateObject private var calendar = CalendarStore()

    init() {
        Brand.applyAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(heartRate)
                .environmentObject(store)
                .environmentObject(routes)
                .environmentObject(strava)
                .environmentObject(library)
                .environmentObject(calendar)
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

/// Tabs: Today, the week around it, activities from Intervals, and the Run Guide run player.
/// A custom container rather than TabView, so the brand tab bar can rise in with the launch animation.
/// All four tabs stay alive so each keeps its scroll position and navigation.
struct RootView: View {
    @StateObject private var launch = LaunchState()
    @State private var showSplash = true
    @State private var tab: AppTab = .today

    var body: some View {
        ZStack {
            // The pages end at the top of the tab bar, so nothing scrolls underneath it.
            VStack(spacing: 0) {
                ZStack {
                    page(.today) { TodayView() }
                    page(.week) { WeekView() }
                    page(.activities) { ActivitiesView() }
                    page(.run) { HomeView() }
                }
                BrandTabBar(selection: $tab)
                    .offset(y: launch.revealed ? 0 : 140)
            }
            .background(Brand.forest.ignoresSafeArea())
            .tint(Brand.accent)
            .font(.brand(.body))
            .environmentObject(launch)

            if showSplash {
                LaunchSplash(launch: launch) { showSplash = false }
            }
        }
    }

    private func page<Content: View>(_ which: AppTab, @ViewBuilder _ content: () -> Content) -> some View {
        let shown = tab == which
        return content()
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }
}
