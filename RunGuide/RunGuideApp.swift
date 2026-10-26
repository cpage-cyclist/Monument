import SwiftUI

@main
struct RunGuideApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var heartRate = HeartRateMonitor()
    @StateObject private var sensors = CyclingSensors()
    @StateObject private var store = RunStore()
    @StateObject private var routes = RouteStore()
    @StateObject private var strava = StravaAccount()
    @StateObject private var library = ActivityLibrary()
    @StateObject private var calendar = CalendarStore()
    @StateObject private var workouts = WorkoutLibrary()
    @StateObject private var rider = RiderStore()

    init() {
        Brand.applyAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(heartRate)
                .environmentObject(sensors)
                .environmentObject(store)
                .environmentObject(routes)
                .environmentObject(strava)
                .environmentObject(library)
                .environmentObject(calendar)
                .environmentObject(workouts)
                .environmentObject(rider)
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

/// Tabs: Today, the calendar, activities from Intervals, and Record.
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
                    page(.calendar) { CalendarView() }
                    page(.activities) { ActivitiesView() }
                    page(.record) { RecordView() }
                    page(.rider) { RiderView() }
                }
                BrandTabBar(selection: $tab)
                    .offset(y: launch.revealed ? 0 : 140)
            }
            .background(Brand.forest.ignoresSafeArea())
            .tint(Brand.accent)
            .font(.brand(.body))
            .environmentObject(launch)
            .environment(\.switchTab) { tab = $0 }

            if showSplash {
                LaunchSplash(launch: launch, title: AppTab.today.title) { showSplash = false }
            }
        }
    }

    /// Each page stays alive; switching tabs slides the new one in from the side it sits on in the
    /// tab bar, and the old one out the other way.
    private func page<Content: View>(_ which: AppTab, @ViewBuilder _ content: () -> Content) -> some View {
        let shown = tab == which
        let order = AppTab.allCases
        let here = order.firstIndex(of: which) ?? 0
        let selected = order.firstIndex(of: tab) ?? 0
        let side: CGFloat = here < selected ? -1 : 1
        return content()
            .offset(x: shown ? 0 : side * slide)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
            .animation(.snappy(duration: 0.32), value: tab)
    }

    /// How far a page travels when it slides in or out.
    private let slide: CGFloat = 90
}
