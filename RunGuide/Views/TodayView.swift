import SwiftUI
import Charts
import RunGuideCore

/// Today: fitness, the next planned session (with Start for runs, rides and walks), and the last activity.
struct TodayView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var heartRate: HeartRateMonitor
    @EnvironmentObject private var strava: StravaAccount
    @EnvironmentObject private var library: ActivityLibrary
    @EnvironmentObject private var rider: RiderStore
    @EnvironmentObject private var calendar: CalendarStore
    @StateObject private var tracker = LocationTracker()
    @State private var showSettings = false
    @State private var running: RecordStart?
    /// The totals card shows the last 7 days instead of Monday to Sunday.
    @AppStorage("todayRollingWeek") private var rollingWeek = false
    @State private var logging: ActivitySummary?

    private var today: String { IntervalsDates.day(Date()) }

    var body: some View {
        NavigationStack {
            BrandScrollPage("Today", onRefresh: pullRefresh) {
                EmptyView()
            } accessory: {
                HeaderButton(systemImage: "gearshape", label: "Settings") { showSettings = true }
            } content: {
                    if !settings.hasCredentials {
                        Button("Add your Intervals athlete ID and API key") { showSettings = true }
                            .buttonStyle(.borderedProminent)
                    }

                    FitnessCard(day: calendar.fitness)
                    WeekTotalsCard(days: weekDays, totals: weekTotals, rolling: $rollingWeek)

                    if let last = library.activities.first(where: { !$0.isStravaPlaceholder }) {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle(text: "Last activity")
                            Card {
                                VStack(alignment: .leading, spacing: 10) {
                                    NavigationLink(value: last) {
                                        HStack {
                                            ActivityRow(activity: last)
                                            Image(systemName: "chevron.right")
                                                .font(.brand(.caption, weight: .semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    if !last.isLogged {
                                        Hairline()
                                        Button {
                                            logging = last
                                        } label: {
                                            Label("How did it feel? Log it", systemImage: "square.and.pencil")
                                                .font(.brand(.subheadline, weight: .semibold))
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if let next = TodayPlan.next(events: calendar.upcoming, activities: library.activities, today: today) {
                        NextSessionCard(event: next, today: today) {
                            if let sport = RecordSport(intervalsType: next.type) {
                                running = RecordStart(workout: Workout(plan: WorkoutPlan(event: next), ftp: rider.ftp(settings.thresholdSource, intervalsFallback: library.latestFTP)),
                                                      sport: sport)
                            }
                        }
                    } else {
                        Card {
                            Text("Nothing planned in the next three weeks.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let error = calendar.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.brand(.footnote))
                            .foregroundStyle(.secondary)
                    }
            }
            .navigationTitle("Today")
            .navigationDestination(for: ActivitySummary.self) { ActivityDetailView(summary: $0) }
            .navigationDestination(item: $running) { start in
                PreviewView(workout: start.workout, sport: start.sport, tracker: tracker)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(settings)
                    .environmentObject(heartRate)
                    .environmentObject(strava)
            }
            .sheet(item: $logging) { activity in
                QuickLogView(activity: activity).environmentObject(library)
            }
            .onChange(of: showSettings) { _, showing in
                if !showing { Task { await refresh() } }
            }
            .task { await refresh() }
            .onChange(of: rollingWeek) { _, _ in Task { await loadWeek(force: false) } }
        }
    }

    /// This month's grid, which always holds the whole of this week.
    private var month: MonthGrid { MonthGrid(containing: Date()) }

    /// Last month's grid, for the start of a rolling week early in the month.
    private var previousMonth: MonthGrid { month.shifted(byMonths: -1) }

    private var weekDays: [String] {
        rollingWeek ? IntervalsDates.days(from: IntervalsDates.adding(-6, to: today), through: today)
                    : (month.week(containing: today) ?? [today])
    }

    private var weekTotals: WeekTotals {
        var events: [CalendarEvent] = [], activities: [ActivitySummary] = []
        var seenEvents = Set<Int>(), seenActivities = Set<String>()
        for grid in [month, previousMonth] where weekDays.contains(where: { $0 >= grid.first && $0 <= grid.last }) {
            let data = calendar.windows[grid.first] ?? calendar.data(for: grid)
            for e in data?.events ?? [] where seenEvents.insert(e.id).inserted { events.append(e) }
            for a in data?.activities ?? [] where seenActivities.insert(a.id.value).inserted { activities.append(a) }
        }
        return WeekTotals(DayPlan.build(days: weekDays, events: events, activities: activities))
    }

    /// Loads the grids the totals card needs.
    private func loadWeek(force: Bool) async {
        await calendar.load(month, force: force)
        if rollingWeek, IntervalsDates.adding(-6, to: today) < month.first {
            await calendar.load(previousMonth, force: force)
        }
    }

    /// Pull-to-refresh on the ridge header.
    private func pullRefresh() async {
        async let a: Void = calendar.refreshToday(force: true)
        async let b: Void = library.refresh(force: true)
        async let c: Void = loadWeek(force: true)
        _ = await (a, b, c)
    }

    private func refresh() async {
        guard settings.hasCredentials else { return }
        async let w: Void = loadWeek(force: false)
        async let a: Void = calendar.refreshToday()
        async let b: Void = library.refresh()
        _ = await (a, b)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .overlay { Rectangle().strokeBorder(Brand.hairline, lineWidth: 1) }
    }
}

/// Fitness, fatigue and form as numbers.
struct FitnessCard: View {
    let day: WellnessDay?

    var body: some View {
        Card {
            HStack {
                figure("Fitness", day?.ctl.map { "\(Int($0.rounded()))" })
                figure("Fatigue", day?.atl.map { "\(Int($0.rounded()))" })
                figure("Form", day?.form.map { f in
                    let v = Int(f.rounded())
                    return v > 0 ? "+\(v)" : "\(v)"
                })
            }
        }
    }

    private func figure(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.brand(.caption)).foregroundStyle(.secondary)
            Text(value ?? "–").font(.num(.title, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NextSessionCard: View {
    let event: CalendarEvent
    let today: String
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: heading)
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: event.isRun ? "figure.run" : (event.isRace ? "flag.checkered" : "bicycle"))
                            .foregroundStyle(.secondary)
                        Text(event.name ?? "Session").font(.brand(.title3, weight: .semibold))
                    }

                    HStack(spacing: 18) {
                        if let t = event.movingTime, t > 0 { stat("Duration", Format.clock(t)) }
                        if let l = event.trainingLoad { stat("Load", "\(Int(l.rounded()))") }
                        if let i = event.intensity { stat("IF", String(format: "%.2f", i / 100)) }
                    }

                    let lines = StepOutline.lines(event.description)
                    if !lines.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                Text(line.isHeading ? line.text : "· " + line.text)
                                    .font(line.isHeading ? .brand(.subheadline, weight: .semibold) : .num(.subheadline))
                                    .foregroundStyle(line.isHeading ? .primary : .secondary)
                                    .padding(.top, line.isHeading ? 4 : 0)
                            }
                        }
                    }

                    if RecordSport(intervalsType: event.type) != nil, event.isWorkout, event.day == today {
                        Button(action: onStart) {
                            Label("Start", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
            }
        }
    }

    private var heading: String {
        if event.day == today { return "Today" }
        return "Next · " + DayTitle.text(event.day, today: today)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.brand(.caption)).foregroundStyle(.secondary)
            Text(value).font(.num(.headline))
        }
    }
}

/// This week (Monday to Sunday) or the last 7 days: load done against planned, sessions done, and
/// time, distance and climbing.
struct WeekTotalsCard: View {
    let days: [String]
    let totals: WeekTotals
    @Binding var rolling: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: (rolling ? "Last 7 days" : "This week") + range)
                Spacer()
                Picker("Span", selection: $rolling) {
                    Text("Week").tag(false)
                    Text("7 days").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(Int(totals.doneLoad.rounded()))")
                            .font(.num(.title, weight: .bold))
                        Text(totals.plannedLoad > 0 ? "of \(Int(totals.plannedLoad.rounded())) load" : "load")
                            .font(.brand(.subheadline))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if totals.plannedSessions > 0 {
                            Text("\(totals.doneSessions)/\(totals.plannedSessions) sessions")
                                .font(.num(.subheadline, weight: .medium))
                        }
                    }
                    if totals.plannedLoad > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(Brand.hairline.opacity(0.15))
                                Rectangle().fill(Brand.forest)
                                    .frame(width: geo.size.width * min(totals.progress, 1))
                                if totals.progress > 1 {
                                    Rectangle().fill(Brand.Medal.bronze.flat)
                                        .frame(width: geo.size.width * (totals.progress - 1) / 1.5)
                                        .offset(x: geo.size.width - geo.size.width * (totals.progress - 1) / 1.5)
                                }
                            }
                        }
                        .frame(height: 6)
                        .accessibilityLabel("\(Int((totals.progress * 100).rounded())) percent of planned load done")
                    }
                    Hairline()
                    HStack {
                        figure("Time", totals.seconds > 0 ? Format.clock(totals.seconds) : "–")
                        figure("Distance", totals.metres > 0 ? String(format: "%.0f km", totals.metres / 1000) : "–")
                        figure("Climbing", totals.climbing > 0 ? "\(Int(totals.climbing.rounded())) m" : "–")
                        figure("Activities", "\(totals.activities)")
                    }
                }
            }
        }
    }

    private var range: String {
        guard let a = days.first.flatMap({ IntervalsDates.parseLocal($0 + "T12:00:00") }),
              let b = days.last.flatMap({ IntervalsDates.parseLocal($0 + "T12:00:00") }) else { return "" }
        return " · " + a.formatted(.dateTime.day().month(.abbreviated)) + " – " + b.formatted(.dateTime.day().month(.abbreviated))
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.brand(.caption)).foregroundStyle(.secondary)
            Text(value).font(.num(.headline, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
