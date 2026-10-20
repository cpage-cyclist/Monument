import Foundation
import RunGuideCore

/// Calendar entries, the activities alongside them, and fitness, for the Today and Week
/// tabs. Served from the disk cache first and refreshed in the background, like
/// ActivityLibrary.
@MainActor
final class CalendarStore: ObservableObject {
    struct WindowData {
        var events: [CalendarEvent]
        var activities: [ActivitySummary]
    }

    /// Keyed by the window's first day.
    @Published private(set) var windows: [String: WindowData] = [:]
    /// Planned sessions from yesterday to three weeks ahead, for "next session".
    @Published private(set) var upcoming: [CalendarEvent] = []
    @Published private(set) var fitness: WellnessDay?
    /// Daily fitness for the last 180 days, for the Today charts.
    @Published private(set) var fitnessHistory: [WellnessDay] = []
    @Published private(set) var loading = false
    @Published var lastError: String?

    private let cache: DiskCache
    private let clientProvider: () -> IntervalsClient

    static let maxAge: TimeInterval = 5 * 60
    static let windowsToKeep = 12

    init(cache: DiskCache = .standard(), client: @escaping () -> IntervalsClient = AppSettings.currentClient) {
        self.cache = cache
        self.clientProvider = client
        if let data = cache.read(Self.upcomingKey)?.data,
           let events = try? JSONDecoder().decode([CalendarEvent].self, from: data) {
            upcoming = events
        }
        if let data = cache.read(Self.fitnessKey)?.data,
           let days = try? JSONDecoder().decode([WellnessDay].self, from: data) {
            fitness = WellnessDay.latest(in: days, onOrBefore: IntervalsDates.day(Date()))
            fitnessHistory = days
        }
    }

    private static let upcomingKey = "calendar-upcoming"
    private static let fitnessKey = "fitness-180d"
    static let fitnessDays = 180
    private static func eventsKey(_ w: DayWindow) -> String { "calendar-events-\(w.first)" }
    private static func activitiesKey(_ w: DayWindow) -> String { "calendar-activities-\(w.first)" }

    // MARK: - Today

    func refreshToday(force: Bool = false) async {
        let today = Date()
        let cal = Calendar.current
        let from = IntervalsDates.day(cal.date(byAdding: .day, value: -1, to: today) ?? today)
        let to = IntervalsDates.day(cal.date(byAdding: .day, value: 21, to: today) ?? today)
        let fitFrom = IntervalsDates.day(cal.date(byAdding: .day, value: -(Self.fitnessDays - 1), to: today) ?? today)
        let todayKey = IntervalsDates.day(today)
        let client = clientProvider()

        if force || isStale(Self.upcomingKey) {
            do {
                let data = try await client.eventsData(oldest: from, newest: to)
                upcoming = try JSONDecoder().decode([CalendarEvent].self, from: data)
                cache.write(data, for: Self.upcomingKey)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
        if force || isStale(Self.fitnessKey) {
            if let data = try? await client.wellnessData(oldest: fitFrom, newest: todayKey),
               let days = try? JSONDecoder().decode([WellnessDay].self, from: data) {
                fitness = WellnessDay.latest(in: days, onOrBefore: todayKey)
                fitnessHistory = days
                cache.write(data, for: Self.fitnessKey)
            }
        }
    }

    // MARK: - Week

    func data(for window: DayWindow) -> WindowData? {
        if let loaded = windows[window.first] { return loaded }
        guard let e = cache.read(Self.eventsKey(window))?.data,
              let events = try? JSONDecoder().decode([CalendarEvent].self, from: e) else { return nil }
        let activities = cache.read(Self.activitiesKey(window))
            .flatMap { try? JSONDecoder().decode([ActivitySummary].self, from: $0.data) } ?? []
        return WindowData(events: events, activities: activities)
    }

    func load(_ window: DayWindow, force: Bool = false) async {
        if windows[window.first] == nil, let cached = data(for: window) {
            windows[window.first] = cached
        }
        guard force || windows[window.first] == nil || isStale(Self.eventsKey(window)) else { return }
        loading = true
        defer { loading = false }
        do {
            let client = clientProvider()
            async let e = client.eventsData(oldest: window.first, newest: window.last)
            async let a = client.activitiesData(oldest: window.first, newest: window.last)
            let (eventsData, activitiesData) = try await (e, a)
            let events = try JSONDecoder().decode([CalendarEvent].self, from: eventsData)
            let activities = (try? JSONDecoder().decode([ActivitySummary].self, from: activitiesData)) ?? []
            cache.write(eventsData, for: Self.eventsKey(window))
            cache.write(activitiesData, for: Self.activitiesKey(window))
            cache.trim(prefix: "calendar-events-", keep: Self.windowsToKeep)
            cache.trim(prefix: "calendar-activities-", keep: Self.windowsToKeep)
            windows[window.first] = WindowData(events: events, activities: activities)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Light edits

    func move(_ event: CalendarEvent, to day: String, in window: DayWindow) async {
        await edit(window) { try await $0.moveEvent(id: event.id, to: day) }
    }

    func delete(_ event: CalendarEvent, in window: DayWindow) async {
        await edit(window) { try await $0.deleteEvent(id: event.id) }
    }

    func addNote(on day: String, title: String, text: String, in window: DayWindow) async {
        await edit(window) { try await $0.addNote(on: day, title: title, text: text) }
    }

    private func edit(_ window: DayWindow, _ change: (IntervalsClient) async throws -> Void) async {
        do {
            try await change(clientProvider())
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        // Moves can cross windows, so drop the others rather than show stale days.
        windows = windows.filter { $0.key == window.first }
        await load(window, force: true)
        await refreshToday(force: true)
    }

    private func isStale(_ key: String) -> Bool {
        (cache.read(key)?.age() ?? .infinity) > Self.maxAge
    }
}
