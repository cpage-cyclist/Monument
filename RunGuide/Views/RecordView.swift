import SwiftUI
import RunGuideCore

/// What Record is about to start: the session and the sport it's locked to.
struct RecordStart: Hashable {
    let workout: Workout
    let sport: RecordSport
}

/// Record: choose the sport, then a planned session from Intervals, Just record, or a route.
/// The sport is fixed once a recording starts. Sensors for the chosen sport show up top.
struct RecordView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var heartRate: HeartRateMonitor
    @EnvironmentObject private var sensors: CyclingSensors
    @EnvironmentObject private var routes: RouteStore
    @EnvironmentObject private var strava: StravaAccount
    @EnvironmentObject private var library: ActivityLibrary
    @EnvironmentObject private var rider: RiderStore
    @StateObject private var tracker = LocationTracker()

    @State private var sport: RecordSport = .run
    @State private var day = IntervalsDates.day(Date())
    @State private var planned: [CalendarEvent] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var starting: RecordStart?
    @State private var showSettings = false
    @State private var importing = false
    @State private var pasted = ""

    private var today: String { IntervalsDates.day(Date()) }

    var body: some View {
        NavigationStack {
            BrandScrollPage("Record", onRefresh: load) {
                EmptyView()
            } accessory: {
                HeaderButton(systemImage: "gearshape", label: "Settings") { showSettings = true }
            } content: {
                sportPicker
                Card { SensorStatus(sport: sport, tracker: tracker, power: sensors.power, cadence: sensors.cadence) }

                Button {
                    starting = RecordStart(workout: .justRecord(sport), sport: sport)
                } label: {
                    Label("Just record", systemImage: "record.circle")
                        .font(.brand(.headline, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.forest)
                .controlSize(.large)

                plannedSection
                routesSection

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        NavigationLink {
                            SavedRunsView()
                        } label: {
                            row("Saved recordings", icon: "folder", detail: "\(store.runs.count)")
                        }
                        Hairline()
                        NavigationLink {
                            PasteSessionView(sport: sport) { starting = $0 }
                        } label: {
                            row("Paste a session", icon: "doc.on.clipboard", detail: nil)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Record")
            .navigationDestination(item: $starting) { start in
                PreviewView(workout: start.workout, sport: start.sport, tracker: tracker)
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.gpx, .tcx, .xml]) { result in
                if case .success(let url) = result { routes.importRoute(from: url) }
            }
            .task(id: day) { await load() }
            .onAppear { sport = settings.recordSport }
            .onChange(of: sport) { _, new in settings.recordSport = new }
        }
    }

    // MARK: - Pieces

    private var sportPicker: some View {
        HStack(spacing: 10) {
            ForEach(RecordSport.allCases) { s in
                let on = s == sport
                Button {
                    withAnimation(.snappy) { sport = s }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: s.icon).font(.system(size: 24, weight: on ? .semibold : .regular))
                        Text(s.title).font(.brand(.subheadline, weight: on ? .bold : .medium))
                    }
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .background(on ? Brand.forest : Color.white.opacity(0.35), in: Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
    }

    private var sessions: [CalendarEvent] {
        planned.filter { $0.isWorkout && sport.matches(intervalsType: $0.type) }
    }

    private var plannedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                SectionTitle(text: DayTitle.text(day, today: today), emphasised: day == today)
                Spacer()
                if day != today {
                    Button("Today") { day = today }
                        .font(.brand(.subheadline, weight: .medium))
                        .padding(.trailing, 6)
                }
                Button { day = IntervalsDates.adding(-1, to: day) } label: {
                    Image(systemName: "chevron.left").frame(width: 36, height: 30)
                }
                .accessibilityLabel("Previous day")
                Button { day = IntervalsDates.adding(1, to: day) } label: {
                    Image(systemName: "chevron.right").frame(width: 36, height: 30)
                }
                .accessibilityLabel("Next day")
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    if !settings.hasCredentials {
                        Text("Add your Intervals details in Settings to see planned sessions.")
                            .font(.brand(.footnote)).foregroundStyle(.secondary)
                    } else if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle").font(.brand(.footnote))
                    } else if sessions.isEmpty {
                        Text(loading ? "Loading…" : "No planned \(sport.title.lowercased())s on this day.")
                            .font(.brand(.subheadline)).foregroundStyle(.tertiary)
                    }
                    ForEach(sessions) { event in
                        Button {
                            starting = RecordStart(
                                workout: Workout(plan: WorkoutPlan(event: event), ftp: rider.ftp(settings.thresholdSource, intervalsFallback: library.latestFTP)),
                                sport: sport)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 26))
                                    .foregroundStyle(Brand.forest)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.name ?? "Session").font(.brand(.body, weight: .medium))
                                    Text(DayTitle.sessionLine(event))
                                        .font(.num(.subheadline))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var routesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Routes")
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(routes.routes) { saved in
                        NavigationLink {
                            RouteDetailView(saved: saved, sport: sport, tracker: tracker)
                        } label: {
                            HStack {
                                RouteRow(saved: saved)
                                Image(systemName: "chevron.right").font(.brand(.caption, weight: .semibold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { routes.delete(saved) } label: { Label("Delete route", systemImage: "trash") }
                        }
                        Hairline()
                    }
                    NavigationLink {
                        StravaRoutesView()
                    } label: {
                        row("Your Strava routes", icon: "point.topleft.down.to.point.bottomright.curvepath", detail: nil)
                    }
                    .buttonStyle(.plain)
                    Button { importing = true } label: {
                        row("Import a GPX or TCX file", icon: "square.and.arrow.down", detail: nil)
                    }
                    .buttonStyle(.plain)
                    if let error = routes.lastError {
                        Label(error, systemImage: "exclamationmark.triangle").font(.brand(.footnote))
                    }
                }
            }
        }
    }

    private func row(_ title: String, icon: String, detail: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
            Text(title).font(.brand(.body, weight: .medium))
            Spacer()
            if let detail { Text(detail).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right").font(.brand(.caption, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func load() async {
        guard settings.hasCredentials else { return }
        loading = true
        defer { loading = false }
        do {
            let data = try await settings.client.eventsData(oldest: day, newest: day)
            planned = try JSONDecoder().decode([CalendarEvent].self, from: data)
            errorText = nil
        } catch {
            planned = []
            errorText = error.localizedDescription
        }
    }
}

/// GPS, heart rate and (for rides) power and cadence, as they stand before starting.
struct SensorStatus: View {
    let sport: RecordSport
    @ObservedObject var tracker: LocationTracker
    @ObservedObject var power: CyclingSensor
    @ObservedObject var cadence: CyclingSensor
    @EnvironmentObject private var heartRate: HeartRateMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            gps
            if heartRate.hasPairedStrap {
                status(icon: "heart.fill",
                       text: heartRate.currentBPM.map { "\(heartRate.pairedName ?? "Strap") · \($0) bpm" }
                           ?? "Looking for \(heartRate.pairedName ?? "strap")… put it on to wake it",
                       good: heartRate.currentBPM != nil)
            }
            if sport.usesPower {
                if power.isPaired {
                    status(icon: "bolt.fill",
                           text: power.currentWatts.map { w in
                               "\(power.pairedName ?? "Power") · \(w) W" + (power.currentCadence.map { " · \($0) rpm" } ?? "")
                           } ?? "Looking for \(power.pairedName ?? "power meter")… spin the cranks",
                           good: power.currentWatts != nil)
                }
                if cadence.isPaired {
                    status(icon: "arrow.triangle.2.circlepath",
                           text: cadence.currentCadence.map { "\(cadence.pairedName ?? "Cadence") · \($0) rpm" }
                               ?? "Looking for \(cadence.pairedName ?? "cadence sensor")…",
                           good: cadence.currentCadence != nil)
                }
                if !power.isPaired && !cadence.isPaired {
                    status(icon: "bolt.slash", text: "No power meter paired. Add one in Settings.", good: nil)
                }
            }
        }
        .onAppear { connect() }
        .onChange(of: sport) { _, _ in connect() }
    }

    private func connect() {
        tracker.warmUp()
        heartRate.connect()
        if sport.usesPower {
            power.connect()
            cadence.connect()
        }
    }

    @ViewBuilder private var gps: some View {
        if tracker.authorization == .denied || tracker.authorization == .restricted {
            status(icon: "location.slash", text: "Location is off for Monument. Turn it on in Settings › Monument.", good: false)
        } else if let accuracy = tracker.accuracy {
            status(icon: "location.fill",
                   text: accuracy <= 15 ? "GPS ready (±\(Int(accuracy)) m)" : "GPS settling (±\(Int(accuracy)) m)",
                   good: accuracy <= 15)
        } else {
            status(icon: "location", text: "Finding GPS…", good: nil)
        }
    }

    private func status(icon: String, text: String, good: Bool?) -> some View {
        Label {
            Text(text).font(.brand(.subheadline))
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(good == true ? Brand.forest : (good == false ? Brand.Medal.bronze.flat : Color.secondary))
        }
    }
}

/// Paste a session in Intervals workout text and play it.
struct PasteSessionView: View {
    let sport: RecordSport
    let onStart: (RecordStart) -> Void
    @EnvironmentObject private var library: ActivityLibrary
    @EnvironmentObject private var rider: RiderStore
    @EnvironmentObject private var settings: AppSettings
    @State private var text = ""

    var body: some View {
        BrandForm {
            Section {
                TextEditor(text: $text)
                    .font(.num(.footnote))
                    .frame(minHeight: 180)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } footer: {
                Text("Intervals workout text, e.g.\n- 10m ramp 50-75%\n\n3x\n- 8m 95-100%\n- 4m 55%\n\nm is minutes; metres are mtr.")
                    .font(.num(.caption2))
            }
            Button("Use this session") {
                let plan = WorkoutPlan(text: text, name: "Pasted session", sport: sport.title)
                onStart(RecordStart(workout: Workout(plan: plan, ftp: rider.ftp(settings.thresholdSource, intervalsFallback: library.latestFTP)), sport: sport))
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
                .ridgeNavHeader("Paste")
        .navigationBarTitleDisplayMode(.inline)
    }
}
