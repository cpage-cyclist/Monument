import Foundation
import RunGuideCore

/// Completed activities from Intervals, served from the on-disk cache first and refreshed
/// in the background. Streams never change once an activity is processed, so they're kept
/// until the cache is trimmed; the list and per-activity detail are refetched when stale.
@MainActor
final class ActivityLibrary: ObservableObject {
    @Published private(set) var activities: [ActivitySummary] = []
    @Published private(set) var refreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var dismissedLogPrompts: Set<String>

    private let cache: DiskCache
    private let clientProvider: () -> IntervalsClient
    private let defaults = UserDefaults.standard

    /// How far back the list goes.
    static let listDays = 60
    /// Refetch the list on open if the cached copy is older than this.
    static let listMaxAge: TimeInterval = 5 * 60
    /// Detail (laps, RPE, notes) can change after upload, so refetch if older than this.
    static let detailMaxAge: TimeInterval = 10 * 60
    /// Activities' streams to keep on disk.
    static let streamsToKeep = 40

    init(cache: DiskCache = .standard(), client: @escaping () -> IntervalsClient = AppSettings.currentClient) {
        self.cache = cache
        self.clientProvider = client
        dismissedLogPrompts = Set(UserDefaults.standard.stringArray(forKey: "dismissedLogPrompts") ?? [])
        if let entry = cache.read(CacheKey.activityList),
           let list = try? JSONDecoder().decode([ActivitySummary].self, from: entry.data) {
            activities = list
        }
    }

    /// The activity the quick log should ask about, if any.
    var unlogged: ActivitySummary? {
        LogPrompt.unlogged(in: activities, dismissed: dismissedLogPrompts)
    }

    func dismissLogPrompt(for activity: ActivitySummary) {
        dismissedLogPrompts.insert(activity.id.value)
        defaults.set(Array(dismissedLogPrompts.suffix(200)), forKey: "dismissedLogPrompts")
    }

    // MARK: - List

    /// Refreshes the list if the cached copy is stale (or always, when `force` is set).
    func refresh(force: Bool = false) async {
        if !force, let entry = cache.read(CacheKey.activityList), entry.age() < Self.listMaxAge, !activities.isEmpty {
            return
        }
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let now = Date()
            let oldest = Calendar.current.date(byAdding: .day, value: -Self.listDays, to: now) ?? now
            let data = try await clientProvider().activitiesData(oldest: oldest, newest: now)
            let list = try JSONDecoder().decode([ActivitySummary].self, from: data)
            cache.write(data, for: CacheKey.activityList)
            activities = list
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - One activity

    /// The cached detail straight away (nil if there isn't one).
    func cachedDetail(id: String) -> ActivityDetail? {
        cache.read(CacheKey.detail(id)).flatMap { try? JSONDecoder().decode(ActivityDetail.self, from: $0.data) }
    }

    /// Detail from the cache if fresh, otherwise from Intervals (falling back to a stale copy offline).
    func detail(id: String, force: Bool = false) async throws -> ActivityDetail {
        let key = CacheKey.detail(id)
        let cached = cache.read(key)
        if !force, let cached, cached.age() < Self.detailMaxAge,
           let detail = try? JSONDecoder().decode(ActivityDetail.self, from: cached.data) {
            return detail
        }
        do {
            let data = try await clientProvider().activityData(id: id)
            let detail = try JSONDecoder().decode(ActivityDetail.self, from: data)
            cache.write(data, for: key)
            return detail
        } catch {
            if let cached, let detail = try? JSONDecoder().decode(ActivityDetail.self, from: cached.data) {
                return detail
            }
            throw error
        }
    }

    /// Streams from the cache, or from Intervals the first time.
    func streams(id: String) async throws -> ActivityStreams {
        let key = CacheKey.streams(id)
        let cache = self.cache
        let keep = Self.streamsToKeep
        // A long ride's streams run to a few MB, so read and decode off the main thread.
        if let streams = await Task.detached(priority: .userInitiated, operation: {
            cache.read(key).flatMap { try? ActivityStreams.decode($0.data) }
        }).value {
            return streams
        }
        let data = try await clientProvider().streamsData(id: id)
        return try await Task.detached(priority: .userInitiated) {
            let streams = try ActivityStreams.decode(data)
            cache.write(data, for: key)
            cache.trim(prefix: CacheKey.streamsPrefix, keep: keep)
            return streams
        }.value
    }

    /// Fetches detail and streams for the newest few activities so they open instantly.
    func prefetchRecent(count: Int = 3) async {
        for activity in activities.prefix(count) where !activity.isStravaPlaceholder {
            let id = activity.id.value
            _ = try? await detail(id: id)
            _ = try? await streams(id: id)
        }
    }

    // MARK: - Monument power profile

    /// Days of best efforts the profile is fitted to, ending on the ride's date.
    static let profileDays = 90

    /// Monument's CP/W′ for a ride, fitted to the best efforts in the 90 days up to and
    /// including that ride. Past curves never change, so they're cached for good.
    func profile(for activity: ActivitySummary) async -> PowerProfile? {
        guard let start = activity.startDate else { return nil }
        let cal = Calendar.current
        let to = IntervalsDates.day(start)
        let from = IntervalsDates.day(cal.date(byAdding: .day, value: -(Self.profileDays - 1), to: start) ?? start)
        let key = "curve-Ride-\(from)-\(to)"
        let isToday = cal.isDateInToday(start)

        if let cached = cache.read(key), !(isToday && cached.age() > 3600),
           let curve = try? PowerCurve.decodeFirst(cached.data) {
            return PowerProfile.fitTwoParameter(curve: curve)
        }
        do {
            let data = try await clientProvider().powerCurveData(type: "Ride", from: from, to: to)
            cache.write(data, for: key)
            cache.trim(prefix: "curve-", keep: Self.streamsToKeep)
            return (try PowerCurve.decodeFirst(data)).flatMap { PowerProfile.fitTwoParameter(curve: $0) }
        } catch {
            return nil
        }
    }

    // MARK: - Logging

    /// Saves RPE/feel/note on the activity and any wellness fields for its day, then refreshes.
    func log(_ activity: ActivitySummary, rpe: Int, feel: Int?, note: String, carbsPerHour: Double? = nil,
             wellness: WellnessLog) async throws {
        let client = clientProvider()
        let entry = ActivityLog(rpe: rpe, feel: feel,
                                description: ActivityLog.appending(note: note, to: activity.description),
                                carbsIngested: carbsPerHour.flatMap { ActivityLog.carbs(perHour: $0, movingTime: activity.movingTime) })
        try await client.updateActivity(id: activity.id.value, log: entry)
        if !wellness.isEmpty {
            try await client.logWellness(wellness, on: activity.startDate ?? Date())
        }
        cache.remove(CacheKey.detail(activity.id.value))
        await refresh(force: true)
    }
}
