import SwiftUI
import Charts
import RunGuideCore

/// Today: fitness, the next planned session (with Start for runs), and the last activity.
struct TodayView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var heartRate: HeartRateMonitor
    @EnvironmentObject private var strava: StravaAccount
    @EnvironmentObject private var library: ActivityLibrary
    @EnvironmentObject private var calendar: CalendarStore
    @EnvironmentObject private var launch: LaunchState
    @StateObject private var tracker = LocationTracker()
    @State private var showSettings = false
    @State private var running: Workout?
    @State private var logging: ActivitySummary?
    @StateObject private var puller = PullToRefresh()
    @State private var headerOffset: CGFloat = 0

    private var today: String { IntervalsDates.day(Date()) }

    var body: some View {
        NavigationStack {
            GeometryReader { outer in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                PullRidgeHeader(topInset: outer.safeAreaInsets.top, refreshing: puller.refreshing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(Brand.wordmark)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Settings")
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text("Today")
                        .font(.brand(.largeTitle, weight: .bold))
                        .padding(.top, 4)

                    if !settings.hasCredentials {
                        Button("Add your Intervals athlete ID and API key") { showSettings = true }
                            .buttonStyle(.borderedProminent)
                    }

                    FitnessCard(day: calendar.fitness)
                    FitnessChartsCard(history: calendar.fitnessHistory, today: today)

                    if let next = TodayPlan.next(events: calendar.upcoming, activities: library.activities, today: today) {
                        NextSessionCard(event: next, today: today) {
                            running = WorkoutParser.parse(next.description ?? "", name: next.name ?? "Planned run")
                        }
                    } else {
                        Card {
                            Text("Nothing planned in the next three weeks.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let last = library.activities.first(where: { !$0.isStravaPlaceholder }) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Last activity").font(.headline)
                            Card {
                                VStack(alignment: .leading, spacing: 10) {
                                    NavigationLink(value: last) {
                                        HStack {
                                            ActivityRow(activity: last)
                                            Image(systemName: "chevron.right")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    if !last.isLogged {
                                        Divider()
                                        Button {
                                            logging = last
                                        } label: {
                                            Label("How did it feel? Log it", systemImage: "square.and.pencil")
                                                .font(.subheadline.weight(.semibold))
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if let error = calendar.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                // Rises in with the ridges at launch.
                .offset(y: launch.revealed ? 0 : 420)
                }
            }
            .coordinateSpace(name: BrandScroll.space)
            .ignoresSafeArea(edges: .top)
            .onPreferenceChange(HeaderOffsetKey.self) { offset in
                headerOffset = offset
                puller.update(offset: offset) { await pullRefresh() }
            }
            .overlay(alignment: .top) {
                CollapsedRidgeBar(topInset: outer.safeAreaInsets.top, offset: headerOffset)
                    .ignoresSafeArea(edges: .top)
            }
            }
            .background(Brand.page)
            .toolbar(.hidden, for: .navigationBar)
            .navigationTitle("Today")
            .navigationDestination(for: ActivitySummary.self) { ActivityDetailView(summary: $0) }
            .navigationDestination(item: $running) { workout in
                PreviewView(workout: workout, tracker: tracker)
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
        }
    }

    /// Pull-to-refresh on the ridge header.
    private func pullRefresh() async {
        async let a: Void = calendar.refreshToday(force: true)
        async let b: Void = library.refresh(force: true)
        _ = await (a, b)
    }

    private func refresh() async {
        guard settings.hasCredentials else { return }
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
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "–").font(.title.monospacedDigit().weight(.semibold))
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
            Text(heading).font(.headline)
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: event.isRun ? "figure.run" : (event.isRace ? "flag.checkered" : "bicycle"))
                            .foregroundStyle(.secondary)
                        Text(event.name ?? "Session").font(.title3.weight(.semibold))
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
                                    .font(line.isHeading ? .subheadline.weight(.semibold) : .subheadline.monospacedDigit())
                                    .foregroundStyle(line.isHeading ? .primary : .secondary)
                                    .padding(.top, line.isHeading ? 4 : 0)
                            }
                        }
                    }

                    if event.isRun, event.day == today {
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
        return "Next · " + WeekView.dayTitle(event.day, today: today)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
    }
}

/// Fitness and fatigue on one chart, form underneath, over the last 42 or 180 days.
/// Drag across either chart to read a day's numbers.
struct FitnessChartsCard: View {
    let history: [WellnessDay]
    let today: String

    @AppStorage("fitnessChartDays") private var days = 42
    @State private var selectedDate: Date?

    private struct Point: Identifiable {
        let date: Date
        let day: WellnessDay
        var id: String { day.id }
    }

    private var points: [Point] {
        WellnessDay.recent(history, count: days, today: today).compactMap { d in
            IntervalsDates.parseLocal(d.id + "T12:00:00").map { Point(date: $0, day: d) }
        }
    }

    /// The day under the finger, if any.
    private var selected: Point? {
        guard let selectedDate else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(selected.map { $0.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) } ?? "Trend")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Picker("Range", selection: $days) {
                        Text("42d").tag(42)
                        Text("180d").tag(180)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                }

                if points.count < 2 {
                    Text("No fitness history yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    legend
                    fitnessChart
                    formChart
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            key("Fitness", .blue, selected?.day.ctl)
            key("Fatigue", .pink, selected?.day.atl)
            key("Form", .orange, selected?.day.form, signed: true)
            if let zone = selected?.day.formZone {
                Text(zone.rawValue).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func key(_ label: String, _ color: Color, _ value: Double?, signed: Bool = false) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption).foregroundStyle(.secondary)
            if let value {
                let v = Int(value.rounded())
                Text(signed && v > 0 ? "+\(v)" : "\(v)").font(.caption.monospacedDigit().weight(.semibold))
            }
        }
    }

    private var fitnessChart: some View {
        Chart {
            ForEach(points) { p in
                if let ctl = p.day.ctl {
                    LineMark(x: .value("Day", p.date), y: .value("Load", ctl), series: .value("Series", "Fitness"))
                        .foregroundStyle(.blue)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                if let atl = p.day.atl {
                    LineMark(x: .value("Day", p.date), y: .value("Load", atl), series: .value("Series", "Fatigue"))
                        .foregroundStyle(.pink)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            if let selected {
                RuleMark(x: .value("Day", selected.date)).foregroundStyle(Color.primary.opacity(0.4))
            }
        }
        .chartYScale(domain: loadDomain)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
        }
        .chartXSelection(value: $selectedDate)
        .frame(height: 120)
    }

    private var formChart: some View {
        Chart {
            // Intervals' "optimal" training zone.
            RectangleMark(yStart: .value("Form", -30), yEnd: .value("Form", -10))
                .foregroundStyle(Color.green.opacity(0.12))
            RuleMark(y: .value("Form", 0)).foregroundStyle(Color.secondary.opacity(0.5))
            ForEach(points) { p in
                if let form = p.day.form {
                    AreaMark(x: .value("Day", p.date), yStart: .value("Zero", 0), yEnd: .value("Form", form))
                        .foregroundStyle(Color.orange.opacity(0.25))
                    LineMark(x: .value("Day", p.date), y: .value("Form", form))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            if let selected {
                RuleMark(x: .value("Day", selected.date)).foregroundStyle(Color.primary.opacity(0.4))
            }
        }
        .chartYScale(domain: formDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
        }
        .chartXSelection(value: $selectedDate)
        .frame(height: 90)
    }

    /// Snapped to the data with 10% headroom, like the activity charts.
    private var loadDomain: ClosedRange<Double> {
        let values = points.flatMap { [$0.day.ctl, $0.day.atl].compactMap { $0 } }
        guard let lo = values.min(), let hi = values.max() else { return 0...100 }
        let span = max(hi - lo, 10)
        return max(lo - span * 0.1, 0)...(hi + span * 0.1)
    }

    /// Always shows zero and the optimal band, plus the data with headroom.
    private var formDomain: ClosedRange<Double> {
        let values = points.compactMap(\.day.form)
        let lo = min(values.min() ?? -30, -30), hi = max(values.max() ?? 10, 10)
        let span = hi - lo
        return (lo - span * 0.08)...(hi + span * 0.08)
    }
}
