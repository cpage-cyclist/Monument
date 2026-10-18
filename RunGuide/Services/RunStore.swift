import Foundation
import RunGuideCore

struct SavedRun: Codable, Identifiable, Hashable {
    let id: UUID
    let fileName: String
    let name: String
    let date: Date
    let distance: Double
    let timerTime: Double
    var intervalsActivityId: String?
    var uploaded: Bool
    var stravaActivityId: String?
    var uploadedToStrava: Bool?
}

/// Keeps every recorded run as a .fit file in the app's Documents/Runs folder
/// (visible in the Files app under On My iPhone › Run Guide), plus a small index.
final class RunStore: ObservableObject {
    @Published private(set) var runs: [SavedRun] = []

    let folder: URL
    private let indexURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = documents.appendingPathComponent("Runs", isDirectory: true)
        indexURL = folder.appendingPathComponent("runs.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
    }

    func url(for run: SavedRun) -> URL {
        folder.appendingPathComponent(run.fileName)
    }

    /// Writes the FIT file and adds it to the index. Returns nil if writing failed.
    @discardableResult
    func save(_ recording: ActivityRecording) -> SavedRun? {
        let data = FITEncoder.encode(recording)
        let fileName = Self.fileName(for: recording)
        do {
            try data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
        } catch {
            return nil
        }
        let run = SavedRun(id: UUID(), fileName: fileName, name: recording.name, date: recording.start,
                           distance: recording.totalDistance, timerTime: recording.totalTimerTime,
                           intervalsActivityId: nil, uploaded: false,
                           stravaActivityId: nil, uploadedToStrava: false)
        runs.insert(run, at: 0)
        persist()
        return run
    }

    func markUploadedToStrava(_ run: SavedRun, activityId: String?) {
        guard let i = runs.firstIndex(where: { $0.id == run.id }) else { return }
        runs[i].uploadedToStrava = true
        runs[i].stravaActivityId = activityId
        persist()
    }

    func markUploaded(_ run: SavedRun, activityId: String?) {
        guard let i = runs.firstIndex(where: { $0.id == run.id }) else { return }
        runs[i].uploaded = true
        runs[i].intervalsActivityId = activityId
        persist()
    }

    func delete(_ run: SavedRun) {
        try? FileManager.default.removeItem(at: url(for: run))
        runs.removeAll { $0.id == run.id }
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? Self.decoder.decode([SavedRun].self, from: data) else { return }
        runs = decoded.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.fileName).path) }
    }

    private func persist() {
        guard let data = try? Self.encoder.encode(runs) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    static func fileName(for recording: ActivityRecording) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmm"
        let safe = recording.name
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .prefix(40)
        return "\(f.string(from: recording.start))_\(safe.isEmpty ? "run" : String(safe)).fit"
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
