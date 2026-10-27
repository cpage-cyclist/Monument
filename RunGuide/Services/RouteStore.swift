import Foundation
import RunGuideCore
import UniformTypeIdentifiers

/// What a route is for. Strava marks each route as a run or a ride; imported files have none.
enum RouteSport: String, Codable, Hashable, CaseIterable, Identifiable {
    case run, ride

    var id: String { rawValue }
    var title: String { self == .run ? "Run" : "Ride" }
    var icon: String { self == .run ? "figure.run" : "bicycle" }

    /// Whether a route of this kind suits a recording of `sport` (walks use running routes).
    func suits(_ sport: RecordSport) -> Bool {
        switch sport {
        case .ride: self == .ride
        case .run, .walk: self == .run
        }
    }
}

struct SavedRoute: Codable, Identifiable, Hashable {
    let id: UUID
    let fileName: String
    var name: String
    let length: Double
    let isLoop: Bool
    let turnCount: Int
    let importedAt: Date
    /// Set when imported straight from Strava.
    var stravaID: String?
    /// Strava's last-edited stamp at import, to spot when the route has changed since.
    var stravaUpdatedAt: String?
    /// Run or ride (from Strava); nil for an imported file, which suits any sport.
    var sport: RouteSport?
    /// The route's shape thinned to a few dozen points, kept here so the list draws thumbnails
    /// without opening any GPX files.
    var outline: [GeoPoint]?
    /// The last time a recording started on this route.
    var lastUsedAt: Date?

    /// Most recently used or imported first.
    var recency: Date { max(lastUsedAt ?? .distantPast, importedAt) }

    func suits(_ recordSport: RecordSport) -> Bool { sport?.suits(recordSport) ?? true }
}

extension UTType {
    static let gpx = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
    static let tcx = UTType(importedAs: "com.garmin.tcx", conformingTo: .xml)
}

/// Routes kept on the phone (Documents/Routes), plus the last copy of your Strava route list so
/// it opens instantly and only goes back to Strava when it's stale or you pull to refresh.
@MainActor
final class RouteStore: ObservableObject {
    @Published private(set) var routes: [SavedRoute] = []
    @Published var lastError: String?

    /// Your routes on Strava, as last fetched (shown straight away from disk).
    @Published private(set) var stravaRoutes: [StravaRoute] = []
    @Published private(set) var stravaFetchedAt: Date?
    @Published private(set) var stravaLoading = false
    @Published var stravaError: String?
    /// Strava route thumbnails, decoded once per list rather than on every scroll.
    private(set) var stravaOutlines: [String: [GeoPoint]] = [:]

    let folder: URL
    private let indexURL: URL
    private let stravaListURL: URL
    private var cache: [UUID: Route] = [:]

    /// How long the Strava list is trusted before it's quietly refetched on opening.
    static let stravaMaxAge: TimeInterval = 12 * 3600
    static let outlinePoints = 60

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = documents.appendingPathComponent("Routes", isDirectory: true)
        indexURL = folder.appendingPathComponent("routes.json")
        stravaListURL = folder.appendingPathComponent("strava-routes.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
        loadStravaList()
        backfillOutlines()
    }

    // MARK: - Routes on the phone

    /// Most recently used or imported first.
    var byRecency: [SavedRoute] { routes.sorted { $0.recency > $1.recency } }

    /// The few routes to offer first for a sport.
    func recent(for sport: RecordSport, limit: Int = 3) -> [SavedRoute] {
        Array(byRecency.filter { $0.suits(sport) }.prefix(limit))
    }

    func saved(forStrava id: String) -> SavedRoute? { routes.first { $0.stravaID == id } }

    /// True when the route has been edited on Strava since it was imported.
    func isOutdated(_ strava: StravaRoute) -> Bool {
        guard let saved = saved(forStrava: strava.id),
              let remote = strava.updatedAt, let local = saved.stravaUpdatedAt else { return false }
        return remote != local
    }

    /// Import a GPX/TCX file from Files, the share sheet or "Open in".
    @discardableResult
    func importRoute(from url: URL) -> SavedRoute? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            return importRoute(data: data,
                               fileExtension: url.pathExtension.lowercased() == "tcx" ? "tcx" : "gpx",
                               fallbackName: url.deletingPathExtension().lastPathComponent)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Import route file contents (e.g. a GPX downloaded from Strava).
    /// Re-importing the same Strava route replaces the old copy, keeping its name and history.
    @discardableResult
    func importRoute(data: Data, fileExtension: String = "gpx", fallbackName: String,
                     strava: StravaRoute? = nil) -> SavedRoute? {
        do {
            let route = try RouteParser.parse(data: data, fallbackName: fallbackName)
            let previous = strava.flatMap { saved(forStrava: $0.id) }
            if let previous { delete(previous) }
            let id = UUID()
            let fileName = "\(id.uuidString).\(fileExtension)"
            try data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
            let saved = SavedRoute(id: id, fileName: fileName, name: route.name, length: route.length,
                                   isLoop: route.isLoop, turnCount: route.turns.count, importedAt: Date(),
                                   stravaID: strava?.id, stravaUpdatedAt: strava?.updatedAt,
                                   sport: strava?.sport,
                                   outline: RouteOutline.simplify(route.points, maxPoints: Self.outlinePoints),
                                   lastUsedAt: previous?.lastUsedAt)
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

    func markUsed(_ id: UUID) {
        guard let i = routes.firstIndex(where: { $0.id == id }) else { return }
        routes[i].lastUsedAt = Date()
        persist()
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

    // MARK: - Strava list

    /// Shows the saved list at once; goes back to Strava only when it's stale (or forced by a pull).
    func refreshStravaRoutes(using strava: StravaAccount, force: Bool = false) async {
        guard strava.isConnected, !stravaLoading else { return }
        let fresh = stravaFetchedAt.map { Date().timeIntervalSince($0) < Self.stravaMaxAge } ?? false
        guard force || !fresh || stravaRoutes.isEmpty else { return }
        stravaLoading = true
        defer { stravaLoading = false }
        do {
            let list = try await strava.routes()
            setStravaList(list, fetchedAt: Date())
            if let data = try? Self.encoder.encode(StravaListFile(fetchedAt: Date(), routes: list)) {
                try? data.write(to: stravaListURL, options: .atomic)
            }
            stravaError = nil
        } catch {
            stravaError = error.localizedDescription
        }
    }

    /// Forget the saved Strava list (e.g. on disconnect).
    func clearStravaList() {
        try? FileManager.default.removeItem(at: stravaListURL)
        setStravaList([], fetchedAt: nil)
    }

    private struct StravaListFile: Codable {
        let fetchedAt: Date
        let routes: [StravaRoute]
    }

    private func loadStravaList() {
        guard let data = try? Data(contentsOf: stravaListURL),
              let file = try? Self.decoder.decode(StravaListFile.self, from: data) else { return }
        setStravaList(file.routes, fetchedAt: file.fetchedAt)
    }

    private func setStravaList(_ list: [StravaRoute], fetchedAt: Date?) {
        var outlines: [String: [GeoPoint]] = [:]
        for route in list {
            if let encoded = route.summaryPolyline, let points = RouteOutline.decodePolyline(encoded), points.count > 1 {
                outlines[route.id] = RouteOutline.simplify(points, maxPoints: Self.outlinePoints)
            }
        }
        stravaOutlines = outlines
        stravaRoutes = list
        stravaFetchedAt = fetchedAt
    }

    // MARK: - Index

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? Self.decoder.decode([SavedRoute].self, from: data) else { return }
        routes = decoded.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.fileName).path) }
    }

    /// Routes saved before outlines existed get one, a route at a time, without holding up launch.
    private func backfillOutlines() {
        guard routes.contains(where: { $0.outline == nil }) else { return }
        Task { @MainActor in
            for saved in routes where saved.outline == nil {
                await Task.yield()
                guard let route = route(for: saved),
                      let i = routes.firstIndex(where: { $0.id == saved.id }) else { continue }
                routes[i].outline = RouteOutline.simplify(route.points, maxPoints: Self.outlinePoints)
                cache[saved.id] = nil   // only the outline was wanted
            }
            persist()
        }
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
