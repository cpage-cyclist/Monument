import Foundation
import RunGuideCore

/// Calendar entries, the activities alongside them, and fitness, for the Today and Calendar
/// tabs. Served from the disk cache first and refreshed in the background, like
/// ActivityLibrary.
@MainActor
final class CalendarStore: ObservableObject {
    struct WindowData {
        var events: [CalendarEvent]
        var activities: [ActivitySummary]
    }

    /// Keyed by the month grid's first day.
    @Published private(set) var windows: [String: WindowData] = [:]
    /// Planned sessions from yesterday to three weeks ahead, for "next session".
    @Published private(set) var upcoming: [CalendarEvent] = []
    @Published private(set) var fitness: WellnessDay?
    /// Daily fitness for the last 180 days, for the Today charts.
    @Published private(set) var fitnessHistory: [WellnessDay] = []
    @Published private(set) var loading = false
    @Published var lastError: String?
    /// Bumped when something outside the Calendar (the workout builder) changes Intervals' calendar.
    @Published private(set) var revision = 0

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
    private static func eventsKey(_ m: MonthGrid) -> String { "calendar-month-events-\(m.first)" }
    private static func activitiesKey(_ m: MonthGrid) -> String { "calendar-month-activities-\(m.first)" }

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

    // MARK: - Month

    func data(for month: MonthGrid) -> WindowData? {
        if let loaded = windows[month.first] { return loaded }
        guard let e = cache.read(Self.eventsKey(month))?.data,
              let events = try? JSONDecoder().decode([CalendarEvent].self, from: e) else { return nil }
        let activities = cache.read(Self.activitiesKey(month))
            .flatMap { try? JSONDecoder().decode([ActivitySummary].self, from: $0.data) } ?? []
        return WindowData(events: events, activities: activities)
    }

    func load(_ month: MonthGrid, force: Bool = false) async {
        if windows[month.first] == nil, let cached = data(for: month) {
            windows[month.first] = cached
        }
        guard force || windows[month.first] == nil || isStale(Self.eventsKey(month)) else { return }
        loading = true
        defer { loading = false }
        do {
            let client = clientProvider()
            async let e = client.eventsData(oldest: month.first, newest: month.last)
            async let a = client.activitiesData(oldest: month.first, newest: month.last)
            let (eventsData, activitiesData) = try await (e, a)
            let events = try JSONDecoder().decode([CalendarEvent].self, from: eventsData)
            let activities = (try? JSONDecoder().decode([ActivitySummary].self, from: activitiesData)) ?? []
            cache.write(eventsData, for: Self.eventsKey(month))
            cache.write(activitiesData, for: Self.activitiesKey(month))
            cache.trim(prefix: "calendar-month-events-", keep: Self.windowsToKeep)
            cache.trim(prefix: "calendar-month-activities-", keep: Self.windowsToKeep)
            windows[month.first] = WindowData(events: events, activities: activities)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Projection

    /// Planned sessions from today to `aheadEnd`, and today's activities, for projecting fitness.
    @Published private(set) var ahead = WindowData(events: [], activities: [])
    @Published private(set) var aheadEnd: String = ""
    private var aheadFetched: Date?

    /// Makes sure planned sessions are loaded from today through `end`.
    func loadAhead(through end: String, force: Bool = false) async {
        let today = IntervalsDates.day(Date())
        let target = max(end, IntervalsDates.adding(28, to: today))
        let fresh = aheadFetched.map { Date().timeIntervalSince($0) < Self.maxAge } ?? false
        guard force || !fresh || aheadEnd < target else { return }
        do {
            let client = clientProvider()
            async let e = client.eventsData(oldest: today, newest: target)
            async let a = client.activitiesData(oldest: today, newest: today)
            let (eventsData, activitiesData) = try await (e, a)
            ahead = WindowData(events: try JSONDecoder().decode([CalendarEvent].self, from: eventsData),
                               activities: (try? JSONDecoder().decode([ActivitySummary].self, from: activitiesData)) ?? [])
            aheadEnd = target
            aheadFetched = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Fitness, fatigue and form projected from the last known day through `end`.
    func projection(through end: String) -> [WellnessDay] {
        let today = IntervalsDates.day(Date())
        guard end >= today else { return [] }
        return FitnessProjection.project(
            history: fitnessHistory,
            planned: FitnessProjection.plannedLoads(events: ahead.events, activities: ahead.activities, from: today),
            completed: FitnessProjection.completedLoads(ahead.activities),
            today: today, through: end)
    }

    // MARK: - Light edits

    func move(_ event: CalendarEvent, to day: String, in month: MonthGrid) async {
        await edit(month) { try await $0.moveEvent(id: event.id, to: day) }
    }

    func delete(_ event: CalendarEvent, in month: MonthGrid) async {
        await edit(month) { try await $0.deleteEvent(id: event.id) }
    }

    func addNote(on day: String, title: String, text: String, in month: MonthGrid) async {
        await edit(month) { try await $0.addNote(on: day, title: title, text: text) }
    }

    private func edit(_ month: MonthGrid, _ change: (IntervalsClient) async throws -> Void) async {
        do {
            try await change(clientProvider())
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        // Moves can cross months, so drop the others rather than show stale days.
        windows = windows.filter { $0.key == month.first }
        await load(month, force: true)
        await loadAhead(through: aheadEnd, force: true)
        await refreshToday(force: true)
    }

    /// Something else changed the calendar: forget what's loaded so screens fetch it again.
    func calendarChanged() {
        windows = [:]
        aheadFetched = nil
        revision += 1
    }

    private func isStale(_ key: String) -> Bool {
        (cache.read(key)?.age() ?? .infinity) > Self.maxAge
    }
}
