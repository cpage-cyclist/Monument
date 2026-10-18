import SwiftUI
import RunGuideCore

struct SavedRunsView: View {
    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var strava: StravaAccount
    @State private var uploading: UUID?
    @State private var stravaUploading: UUID?
    @State private var errorText: String?

    var body: some View {
        List {
            if store.runs.isEmpty {
                Text("Runs you record are saved here as FIT files.")
                    .foregroundStyle(.secondary)
            }
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }
            ForEach(store.runs) { run in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.name)
                        Text("\(run.date.formatted(date: .abbreviated, time: .shortened)) · \(Format.km(run.distance)) · \(Format.clock(run.timerTime))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if uploading == run.id {
                        ProgressView()
                    } else if run.uploaded {
                        Image(systemName: "checkmark.icloud").foregroundStyle(.green)
                    } else {
                        Button {
                            Task { await upload(run) }
                        } label: {
                            Image(systemName: "icloud.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!settings.hasCredentials)
                    }
                    if strava.isConnected {
                        if stravaUploading == run.id {
                            ProgressView()
                        } else if run.uploadedToStrava == true {
                            Image(systemName: "checkmark.circle").foregroundStyle(.orange)
                        } else {
                            Button {
                                Task { await uploadToStrava(run) }
                            } label: {
                                Image(systemName: "arrow.up.circle").foregroundStyle(.orange)
                            }
                            .buttonStyle(.borderless)
                            .disabled(!strava.hasUploadAccess)
                        }
                    }
                    ShareLink(item: store.url(for: run)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { store.delete(run) }
                }
            }
        }
        .navigationTitle("Saved runs")
    }

    private func uploadToStrava(_ run: SavedRun) async {
        stravaUploading = run.id
        errorText = nil
        defer { stravaUploading = nil }
        do {
            let id = try await strava.uploadActivity(fileURL: store.url(for: run), name: run.name,
                                                     description: "", externalID: run.fileName)
            store.markUploadedToStrava(run, activityId: id)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func upload(_ run: SavedRun) async {
        uploading = run.id
        errorText = nil
        defer { uploading = nil }
        do {
            let id = try await settings.client.uploadActivity(fileURL: store.url(for: run), name: run.name, description: "")
            store.markUploaded(run, activityId: id)
        } catch {
            errorText = error.localizedDescription
        }
    }
}
