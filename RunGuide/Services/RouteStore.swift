import Foundation
import RunGuideCore
import UniformTypeIdentifiers

struct SavedRoute: Codable, Identifiable, Hashable {
    let id: UUID
    let fileName: String
    var name: String
    let length: Double
    let isLoop: Bool
    let turnCount: Int
    let importedAt: Date
}

extension UTType {
    static let gpx = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
    static let tcx = UTType(importedAs: "com.garmin.tcx", conformingTo: .xml)
}

/// Routes imported from Strava (GPX/TCX), kept in Documents/Routes.
@MainActor
final class RouteStore: ObservableObject {
    @Published private(set) var routes: [SavedRoute] = []
    @Published var lastError: String?

    let folder: URL
    private let indexURL: URL
    private var cache: [UUID: Route] = [:]

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = documents.appendingPathComponent("Routes", isDirectory: true)
        indexURL = folder.appendingPathComponent("routes.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
    }

    /// Import a GPX/TCX file from Files, the share sheet or "Open in".
    @discardableResult
    func importRoute(from url: URL) -> SavedRoute? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let fallback = url.deletingPathExtension().lastPathComponent
            let route = try RouteParser.parse(data: data, fallbackName: fallback)
            let ext = url.pathExtension.lowercased() == "tcx" ? "tcx" : "gpx"
            let id = UUID()
            let fileName = "\(id.uuidString).\(ext)"
            try data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
            let saved = SavedRoute(id: id, fileName: fileName, name: route.name, length: route.length,
                                   isLoop: route.isLoop, turnCount: route.turns.count, importedAt: Date())
            routes.insert(saved, at: 0)
            cache[id] = route
            persist()
            lastError = nil
            return saved
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func route(for saved: SavedRoute) -> Route? {
        if let r = cache[saved.id] { return r }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(saved.fileName)),
              let r = try? RouteParser.parse(data: data, fallbackName: saved.name) else { return nil }
        cache[saved.id] = r
        return r
    }

    func rename(_ saved: SavedRoute, to name: String) {
        guard let i = routes.firstIndex(where: { $0.id == saved.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        routes[i].name = trimmed
        persist()
    }

    func delete(_ saved: SavedRoute) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(saved.fileName))
        routes.removeAll { $0.id == saved.id }
        cache[saved.id] = nil
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? Self.decoder.decode([SavedRoute].self, from: data) else { return }
        routes = decoded.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.fileName).path) }
    }

    private func persist() {
        guard let data = try? Self.encoder.encode(routes) else { return }
        try? data.write(to: indexURL, options: .atomic)
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
