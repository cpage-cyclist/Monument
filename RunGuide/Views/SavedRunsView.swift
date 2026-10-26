import SwiftUI
import RunGuideCore

/// Every recorded run. Tap one for its upload, share and delete options.
struct SavedRunsView: View {
    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var strava: StravaAccount

    var body: some View {
        List {
            if store.runs.isEmpty {
                Text("Runs you record are saved here as FIT files.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.runs) { run in
                NavigationLink {
                    SavedRunDetailView(runID: run.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(run.name)
                            Text("\(run.date.formatted(date: .abbreviated, time: .shortened)) · \(Format.km(run.distance)) · \(Format.clock(run.timerTime))")
                                .font(.brand(.caption))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        // Status only: tap the run for the actions.
                        Image(systemName: run.uploaded ? "checkmark.icloud" : "icloud.slash")
                            .foregroundStyle(run.uploaded ? .green : .secondary)
                            .accessibilityLabel(run.uploaded ? "On Intervals" : "Not on Intervals")
                        if strava.isConnected {
                            Image(systemName: run.uploadedToStrava == true ? "checkmark.circle" : "circle.dashed")
                                .foregroundStyle(run.uploadedToStrava == true ? .orange : .secondary)
                                .accessibilityLabel(run.uploadedToStrava == true ? "On Strava" : "Not on Strava")
                        }
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { store.delete(run) }
                }
            }
        }
        .navigationTitle("Saved runs")
    }
}

/// One saved run: upload it to Intervals or Strava, share the FIT file, or delete it.
struct SavedRunDetailView: View {
    let runID: UUID

    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var strava: StravaAccount
    @Environment(\.dismiss) private var dismiss

    @State private var intervalsBusy = false
    @State private var stravaBusy = false
    @State private var intervalsError: String?
    @State private var stravaError: String?
    @State private var confirmDelete = false

    private var run: SavedRun? { store.runs.first { $0.id == runID } }

    var body: some View {
        List {
            if let run {
                Section {
                    LabeledContent("Date", value: run.date.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Distance", value: Format.km(run.distance))
                    LabeledContent("Time", value: Format.clock(run.timerTime))
                }

                Section {
                    if run.uploaded {
                        Label("Uploaded", systemImage: "checkmark.icloud")
                            .foregroundStyle(.green)
                    } else {
                        Button {
                            Task { await uploadToIntervals(run) }
                        } label: {
                            HStack {
                                Label("Upload to Intervals", systemImage: "icloud.and.arrow.up")
                                Spacer()
                                if intervalsBusy { ProgressView() }
                            }
                        }
                        .disabled(intervalsBusy || !settings.hasCredentials)
                    }
                    if let intervalsError {
                        Text(intervalsError).font(.brand(.footnote)).foregroundStyle(.red)
                    }
                } header: {
                    Text("Intervals.icu")
                } footer: {
                    if !settings.hasCredentials { Text("Add your Intervals athlete ID and API key in Settings.") }
                }

                Section {
                    if !strava.isConnected {
                        Text("Connect Strava in Settings to upload runs there.")
                            .foregroundStyle(.secondary)
                    } else if run.uploadedToStrava == true {
                        Label("Uploaded", systemImage: "checkmark.circle")
                            .foregroundStyle(.orange)
                        if let id = run.stravaActivityId, !id.isEmpty,
                           let url = URL(string: "https://www.strava.com/activities/\(id)") {
                            Link(destination: url) {
                                Label("Open on Strava", systemImage: "arrow.up.right.square")
                            }
                        }
                    } else {
                        Button {
                            Task { await uploadToStrava(run) }
                        } label: {
                            HStack {
                                Label(stravaBusy ? "Uploading… (Strava can take a minute)" : "Upload to Strava",
                                      systemImage: "arrow.up.circle")
                                Spacer()
                                if stravaBusy { ProgressView() }
                            }
                        }
                        .tint(.orange)
                        .disabled(stravaBusy || !strava.hasUploadAccess)
                    }
                    if let stravaError {
                        Text(stravaError).font(.brand(.footnote)).foregroundStyle(.red)
                    }
                } header: {
                    Text("Strava")
                } footer: {
                    if strava.isConnected && !strava.hasUploadAccess {
                        Text("Reconnect Strava in Settings and allow uploads.")
                    }
                }

                Section {
                    ShareLink(item: store.url(for: run)) {
                        Label("Share FIT file", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete run", systemImage: "trash")
                    }
                }
            } else {
                Text("This run has been deleted.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(run?.name ?? "Run")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this run?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let run { store.delete(run) }
                dismiss()
            }
        } message: {
            Text("The FIT file is removed from this phone. Copies already on Intervals or Strava stay there.")
        }
    }

    private func uploadToIntervals(_ run: SavedRun) async {
        intervalsBusy = true
        intervalsError = nil
        defer { intervalsBusy = false }
        let client = settings.client, fileURL = store.url(for: run)
        do {
            let id = try await BackgroundTime.run("Intervals upload") {
                try await client.uploadActivity(fileURL: fileURL, name: run.name, description: "")
            }
            store.markUploaded(run, activityId: id)
        } catch {
            intervalsError = error.localizedDescription
        }
    }

    private func uploadToStrava(_ run: SavedRun) async {
        stravaBusy = true
        stravaError = nil
        defer { stravaBusy = false }
        let fileURL = store.url(for: run)
        do {
            let id = try await BackgroundTime.run("Strava upload") {
                try await strava.uploadActivity(fileURL: fileURL, name: run.name, description: "",
                                                externalID: run.fileName, sportType: (run.sport ?? .run).stravaType)
            }
            store.markUploadedToStrava(run, activityId: id)
        } catch {
            stravaError = error.localizedDescription
        }
    }
}
