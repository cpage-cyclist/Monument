import SwiftUI
import RunGuideCore

/// Recent activities from Intervals, newest first. Opens from the cache straight away and
/// refreshes in the background.
struct ActivitiesView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var heartRate: HeartRateMonitor
    @EnvironmentObject private var strava: StravaAccount
    @EnvironmentObject private var library: ActivityLibrary
    @State private var showSettings = false
    @State private var logging: LogTarget?

    /// The activity being logged, and whether the prompt card opened it.
    struct LogTarget: Identifiable {
        let activity: ActivitySummary
        let fromPrompt: Bool
        var id: String { activity.id.value }
    }

    var body: some View {
        NavigationStack {
            BrandScrollPage(onRefresh: { await library.refresh(force: true) }) {
                PageTitle(text: "Activities")
            } accessory: {
                HeaderButton(systemImage: "gearshape", label: "Settings") { showSettings = true }
            } content: {
                if !settings.hasCredentials {
                    VStack(alignment: .leading, spacing: 6) {
                        Button("Add your Intervals athlete ID and API key") { showSettings = true }
                            .buttonStyle(.borderedProminent)
                        Text("Monument reads your activities from Intervals.icu.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let unlogged = library.unlogged {
                    Card {
                        LogPromptCard(activity: unlogged) {
                            logging = LogTarget(activity: unlogged, fromPrompt: true)
                        } onDismiss: {
                            withAnimation { library.dismissLogPrompt(for: unlogged) }
                        }
                    }
                }

                if let error = library.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(days, id: \.day) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(text: group.title)
                        Card {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(group.activities.enumerated()), id: \.element.id) { index, activity in
                                    if index > 0 { Hairline().padding(.vertical, 10) }
                                    NavigationLink(value: activity) {
                                        HStack {
                                            ActivityRow(activity: activity)
                                            Image(systemName: "chevron.right")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button {
                                            logging = LogTarget(activity: activity, fromPrompt: false)
                                        } label: {
                                            Label(activity.isLogged ? "Edit log" : "Log", systemImage: "square.and.pencil")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                if hiddenStravaCount > 0 {
                    Text("\(hiddenStravaCount) recorded in the Strava app aren't shown: Strava doesn't let Intervals share them. Activities synced straight to Intervals (Wahoo, Run Guide) appear here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if settings.hasCredentials && library.activities.isEmpty && !library.refreshing && library.lastError == nil {
                    Text("No activities in the last \(ActivityLibrary.listDays) days.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Activities")
            .navigationDestination(for: ActivitySummary.self) { activity in
                ActivityDetailView(summary: activity)
            }
            .overlay {
                if library.refreshing && library.activities.isEmpty { ProgressView() }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(settings)
                    .environmentObject(heartRate)
                    .environmentObject(strava)
            }
            .sheet(item: $logging) { target in
                QuickLogView(activity: target.activity, fromPrompt: target.fromPrompt)
                    .environmentObject(library)
            }
            .onChange(of: showSettings) { _, showing in
                if !showing { Task { await library.refresh(force: library.activities.isEmpty) } }
            }
            .task {
                guard settings.hasCredentials else { return }
                await library.refresh()
                await library.prefetchRecent()
            }
        }
    }

    private var visible: [ActivitySummary] {
        library.activities.filter { !$0.isStravaPlaceholder }
    }

    private var hiddenStravaCount: Int {
        library.activities.count - visible.count
    }

    private struct DayGroup {
        let day: String
        let title: String
        let activities: [ActivitySummary]
    }

    private var days: [DayGroup] {
        var order: [String] = []
        var groups: [String: [ActivitySummary]] = [:]
        for a in visible {
            let day = String((a.startDateLocal ?? "").prefix(10))
            if groups[day] == nil { order.append(day) }
            groups[day, default: []].append(a)
        }
        return order.map { day in
            DayGroup(day: day, title: Self.dayTitle(day), activities: groups[day] ?? [])
        }
    }

    static func dayTitle(_ day: String) -> String {
        guard let date = IntervalsDates.parseLocal(day + "T12:00:00") else { return day }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }
}

struct ActivityRow: View {
    let activity: ActivitySummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: ActivityRow.icon(for: activity))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(activity.name ?? activity.type ?? "Activity")
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if !activity.isLogged {
                        Circle().fill(.orange).frame(width: 7, height: 7)
                            .accessibilityLabel("Not logged")
                    }
                }
                Text(ActivityRow.line(for: activity))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let load = activity.trainingLoad {
                Text("\(Int(load.rounded()))")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Load \(Int(load.rounded()))")
            }
        }
        .padding(.vertical, 2)
    }

    static func icon(for a: ActivitySummary) -> String {
        let type = (a.type ?? "").lowercased()
        if type.contains("run") { return "figure.run" }
        if type.contains("ride") || type.contains("cycl") { return "bicycle" }
        if type.contains("swim") { return "figure.pool.swim" }
        return "figure.mixed.cardio"
    }

    /// e.g. "1:58:12 · 58.0 km · 260 W NP" or "40:00 · 7.54 km · 5:18/km".
    static func line(for a: ActivitySummary) -> String {
        var parts: [String] = []
        if let t = a.movingTime, t > 0 { parts.append(Format.clock(t)) }
        if let d = a.distance, d > 0 { parts.append(String(format: "%.1f km", d / 1000)) }
        if let np = a.normalizedPower, np > 0 {
            parts.append("\(Int(np.rounded())) W NP")
        } else if a.isRun, let d = a.distance, let t = a.movingTime, d > 0 {
            parts.append(Format.pace(t / (d / 1000)) + "/km")
        } else if let hr = a.averageHeartRate {
            parts.append("\(Int(hr.rounded())) bpm")
        }
        return parts.joined(separator: " · ")
    }
}
