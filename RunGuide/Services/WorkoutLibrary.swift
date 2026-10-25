import Foundation
import RunGuideCore

/// The Intervals workout library, and saving from the builder to the calendar and/or library.
@MainActor
final class WorkoutLibrary: ObservableObject {
    @Published private(set) var folders: [LibraryFolder] = []
    @Published private(set) var loading = false
    @Published var lastError: String?

    private let cache: DiskCache
    private let clientProvider: () -> IntervalsClient
    private static let key = "library-folders"

    init(cache: DiskCache = .standard(), client: @escaping () -> IntervalsClient = AppSettings.currentClient) {
        self.cache = cache
        self.clientProvider = client
        if let data = cache.read(Self.key)?.data,
           let folders = try? JSONDecoder().decode([LibraryFolder].self, from: data) {
            self.folders = folders
        }
    }

    /// Folders only (not training plans), in Intervals' order.
    var saveFolders: [LibraryFolder] { folders.filter { ($0.type ?? "FOLDER") == "FOLDER" } }

    func load(force: Bool = false) async {
        guard force || folders.isEmpty || (cache.read(Self.key)?.age() ?? .infinity) > CalendarStore.maxAge else { return }
        loading = true
        defer { loading = false }
        do {
            let data = try await clientProvider().foldersData()
            folders = try JSONDecoder().decode([LibraryFolder].self, from: data)
            cache.write(data, for: Self.key)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Where the workout came from, so saving can update it in place.
    enum Origin: Hashable, Identifiable {
        case new(day: String?)
        case event(CalendarEvent)
        case library(LibraryWorkout)

        var id: String {
            switch self {
            case .new(let day): "new-\(day ?? "")"
            case .event(let e): "event-\(e.id)"
            case .library(let w): "library-\(w.id)"
            }
        }
    }

    struct SaveChoice {
        /// Rewrite the calendar entry or library workout it was opened from.
        var updateOriginal: Bool
        /// Add as a new planned session on this day.
        var addToDay: String?
        /// Save a new copy into this library folder.
        var addToFolder: Int?

        var isEmpty: Bool { !updateOriginal && addToDay == nil && addToFolder == nil }
    }

    /// What Intervals made of the saved workout.
    struct Saved {
        var time: Double?
        var load: Double?
        /// The text parsed into steps (Intervals reports a time).
        var parsed: Bool { (time ?? 0) > 0 }
    }

    /// Saves everywhere chosen. Returns the time and load Intervals worked out for it.
    func save(_ plan: WorkoutPlan, from origin: Origin, choice: SaveChoice, calendar: CalendarStore) async throws -> Saved {
        let client = clientProvider()
        var saved = Saved()
        var calendarTouched = false, libraryTouched = false

        if choice.updateOriginal {
            switch origin {
            case .event(let e):
                let r = try await client.updateWorkoutEvent(id: e.id, plan)
                saved = Saved(time: r.movingTime, load: r.trainingLoad)
                calendarTouched = true
            case .library(let w):
                let r = try await client.updateLibraryWorkout(id: w.id, plan)
                saved = Saved(time: r.movingTime, load: r.trainingLoad)
                libraryTouched = true
            case .new:
                break
            }
        }
        if let day = choice.addToDay {
            let r = try await client.createWorkoutEvent(plan, on: day)
            saved = Saved(time: r.movingTime ?? saved.time, load: r.trainingLoad ?? saved.load)
            calendarTouched = true
        }
        if let folder = choice.addToFolder {
            let r = try await client.createLibraryWorkout(plan, folderId: folder)
            saved = Saved(time: r.movingTime ?? saved.time, load: r.trainingLoad ?? saved.load)
            libraryTouched = true
        }

        if calendarTouched { calendar.calendarChanged() }
        if libraryTouched { await load(force: true) }
        return saved
    }
}
