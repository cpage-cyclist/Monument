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

/// Tabs: Today, Calendar, Activities, Record and Rider.
/// A custom container rather than TabView, so the brand tab bar can rise in with the launch animation.
/// Every tab stays alive so each keeps its scroll position and navigation.
struct RootView: View {
    @StateObject private var launch = LaunchState()
    @State private var showSplash = true
    @State private var tab: AppTab = .today
    /// The page sliding out and the one sliding in while a switch is under way.
    @State private var leaving: AppTab?
    @State private var incoming: AppTab?
    /// +1 when the new tab sits to the right of the old one in the tab bar, -1 to the left.
    @State private var direction: CGFloat = 1

    var body: some View {
        ZStack {
            // The pages end at the top of the tab bar, so nothing scrolls underneath it.
            VStack(spacing: 0) {
                GeometryReader { geo in
                    let width = geo.size.width
                    ZStack {
                        page(.today, width: width) { TodayView() }
                        page(.calendar, width: width) { CalendarView() }
                        page(.activities, width: width) { ActivitiesView() }
                        page(.record, width: width) { RecordView() }
                        page(.rider, width: width) { RiderView() }
                    }
                    .frame(width: width, height: geo.size.height)
                }
                BrandTabBar(selection: tab, onSelect: select)
                    .offset(y: launch.revealed ? 0 : 140)
            }
            .background(Brand.forest.ignoresSafeArea())
            .tint(Brand.accent)
            .font(.brand(.body))
            .environmentObject(launch)
            .environment(\.switchTab, select)

            if showSplash {
                LaunchSplash(launch: launch, title: AppTab.today.title) { showSplash = false }
            }
        }
    }

    /// A full-width push: the new page slides in from the side it sits on in the tab bar while the
    /// old one slides out the other way, both moving together. Only those two pages are drawn;
    /// the rest wait off screen, hidden. Nothing fades, so there's no half-transparent overlap.
    private func page<Content: View>(_ which: AppTab, width: CGFloat,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        let shown = tab == which
        let drawn = shown || which == leaving || which == incoming
        let x: CGFloat = shown ? 0 : (which == leaving ? -direction : direction) * width
        return content()
            .offset(x: x)
            .opacity(drawn ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }

    private func select(_ new: AppTab) {
        guard new != tab else { return }
        let order = AppTab.allCases
        let forward = (order.firstIndex(of: new) ?? 0) > (order.firstIndex(of: tab) ?? 0)
        // First, with no animation, park the incoming page just off the side it comes from and
        // keep the current one drawn...
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            direction = forward ? 1 : -1
            leaving = tab
            incoming = new
        }
        // ...then, on the next frame, push both together.
        DispatchQueue.main.async {
            withAnimation(Self.push) {
                tab = new
            } completion: {
                guard tab == new else { return }
                leaving = nil
                incoming = nil
            }
        }
    }

    private static let push = Animation.smooth(duration: 0.3)
}
