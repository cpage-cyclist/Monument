import SwiftUI
import RunGuideCore

struct HomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var heartRate: HeartRateMonitor
    @EnvironmentObject private var routes: RouteStore
    @StateObject private var tracker = LocationTracker()
    @State private var importing = false

    @State private var date = Date()
    @State private var events: [IntervalsEvent] = []
    @State private var loading = false
    @State private var loadedOnce = false
    @State private var errorText: String?
    @State private var pasted = ""
    @State private var selected: Workout?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Button {
                        Task { await load() }
                    } label: {
                        HStack {
                            Text(loading ? "Loading…" : "Load planned runs")
                            Spacer()
                            if loading { ProgressView() }
                        }
                    }
                    .disabled(loading)

                    if let errorText {
                        Text(errorText).font(.footnote).foregroundStyle(.red)
                    } else if loadedOnce && events.isEmpty && !loading {
                        Text("No planned runs on this day.").font(.footnote).foregroundStyle(.secondary)
                    }

                    ForEach(events) { event in
                        let workout = WorkoutParser.parse(event.description ?? "", name: event.name ?? "Planned run")
                        Button {
                            selected = workout
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(workout.name).foregroundStyle(.primary)
                                Text(stepSummary(workout)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("From Intervals")
                }

                Section {
                    ForEach(routes.routes) { saved in
                        NavigationLink {
                            RouteDetailView(saved: saved, tracker: tracker)
                        } label: {
                            RouteRow(saved: saved)
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { routes.delete(routes.routes[i]) }
                    }
                    Button {
                        importing = true
                    } label: {
                        Label("Import a route (GPX or TCX)", systemImage: "square.and.arrow.down")
                    }
                    if let error = routes.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Routes")
                } footer: {
                    Text("Export a route from Strava as GPX, then AirDrop or share it to Run Guide, or import it from Files.")
                }

                Section {
                    NavigationLink {
                        SavedRunsView()
                    } label: {
                        HStack {
                            Label("Saved runs", systemImage: "folder")
                            Spacer()
                            Text("\(store.runs.count)").foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    TextEditor(text: $pasted)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 140)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Use pasted session") {
                        selected = WorkoutParser.parse(pasted, name: "Pasted session")
                    }
                    .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Or paste a session")
                } footer: {
                    Text("Same format as the Intervals workout builder, e.g.\n- 2km 5:30/km\n5x\n- 1km 4:00/km\n- Float 90s\n\n- 2km")
                        .font(.caption2.monospaced())
                }
            }
            .navigationTitle("Run Guide")
            .toolbar {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(settings)
                    .environmentObject(heartRate)
            }
            .navigationDestination(item: $selected) { workout in
                PreviewView(workout: workout, tracker: tracker)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.gpx, .tcx, .xml]) { result in
                if case .success(let url) = result { routes.importRoute(from: url) }
            }
            .onChange(of: date) { _, _ in
                Task { await load() }
            }
            .task {
                if settings.hasCredentials && !loadedOnce { await load() }
            }
        }
    }

    private func load() async {
        loading = true
        errorText = nil
        defer {
            loading = false
            loadedOnce = true
        }
        do {
            events = try await settings.client.plannedRuns(on: date)
        } catch {
            events = []
            errorText = error.localizedDescription
        }
    }

    private func stepSummary(_ workout: Workout) -> String {
        guard !workout.steps.isEmpty else { return "No readable steps" }
        var parts = ["\(workout.steps.count) steps"]
        if workout.plannedDistance > 0 { parts.append(Format.km(workout.plannedDistance)) }
        if workout.plannedTime > 0 { parts.append(Format.clock(workout.plannedTime) + " timed") }
        return parts.joined(separator: " · ")
    }
}
