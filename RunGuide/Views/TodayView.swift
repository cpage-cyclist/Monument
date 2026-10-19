import SwiftUI
import RunGuideCore

/// Today: fitness, the next planned session (with Start for runs), and the last activity.
struct TodayView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var heartRate: HeartRateMonitor
    @EnvironmentObject private var strava: StravaAccount
    @EnvironmentObject private var library: ActivityLibrary
    @EnvironmentObject private var calendar: CalendarStore
    @StateObject private var tracker = LocationTracker()
    @State private var showSettings = false
    @State private var running: Workout?
    @State private var logging: ActivitySummary?

    private var today: String { IntervalsDates.day(Date()) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !settings.hasCredentials {
                        Button("Add your Intervals athlete ID and API key") { showSettings = true }
                            .buttonStyle(.borderedProminent)
                    }

                    FitnessCard(day: calendar.fitness)

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
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Today")
            .navigationDestination(for: ActivitySummary.self) { ActivityDetailView(summary: $0) }
            .navigationDestination(item: $running) { workout in
                PreviewView(workout: workout, tracker: tracker)
            }
            .refreshable {
                async let a: Void = calendar.refreshToday(force: true)
                async let b: Void = library.refresh(force: true)
                _ = await (a, b)
            }
            .toolbar {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
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
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
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
