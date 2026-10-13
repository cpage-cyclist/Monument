import SwiftUI
import RunGuideCore

struct SavedRunsView: View {
    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var settings: AppSettings
    @State private var uploading: UUID?
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
