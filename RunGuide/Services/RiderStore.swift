import Foundation
import RunGuideCore

/// What the Rider card needs: the athlete's settings, best-power curves for each period, and this
/// year's totals. Served from the disk cache first and refreshed when stale.
@MainActor
final class RiderStore: ObservableObject {
    @Published private(set) var athlete: AthleteProfile?
    @Published private(set) var curves: [String: PowerCurve] = [:]
    @Published private(set) var totals = SeasonTotals()
    @Published private(set) var loading = false
    @Published var lastError: String?

    private let cache: DiskCache
    private let clientProvider: () -> IntervalsClient
    private static let maxAge: TimeInterval = 3 * 3600
    private static let athleteKey = "rider-athlete"
    private static let curvesKey = "rider-curves-Ride"
    private static var totalsKey: String { "rider-season-\(year)" }
    static var year: String { String(IntervalsDates.day(Date()).prefix(4)) }

    init(cache: DiskCache = .standard(), client: @escaping () -> IntervalsClient = AppSettings.currentClient) {
        self.cache = cache
        self.clientProvider = client
        if let d = cache.read(Self.athleteKey)?.data { athlete = try? JSONDecoder().decode(AthleteProfile.self, from: d) }
        if let d = cache.read(Self.curvesKey)?.data, let list = try? PowerCurve.decodeAll(d) {
            curves = RiderCard.byPeriod(list)
        }
        if let d = cache.read(Self.totalsKey)?.data, let list = try? JSONDecoder().decode([ActivitySummary].self, from: d) {
            totals = SeasonTotals(list, year: Self.year)
        }
    }

    /// Monument's CP and W′ from the last 90 days.
    var fitted: PowerProfile? { curves["90d"].flatMap { PowerProfile.fitTwoParameter(curve: $0) } }

    func load(force: Bool = false) async {
        let stale = [Self.athleteKey, Self.curvesKey, Self.totalsKey]
            .contains { (cache.read($0)?.age() ?? .infinity) > Self.maxAge }
        guard force || stale || curves.isEmpty else { return }
        loading = true
        defer { loading = false }
        let client = clientProvider()
        let today = IntervalsDates.day(Date())
        async let a = try? client.athleteData()
        async let c = try? client.powerCurvesData(type: "Ride", curves: RiderPeriod.request)
        async let t = try? client.activitiesData(oldest: Self.year + "-01-01", newest: today, limit: 2000)
        let (athleteData, curveData, totalsData) = await (a, c, t)

        if let athleteData, let profile = try? JSONDecoder().decode(AthleteProfile.self, from: athleteData) {
            athlete = profile
            cache.write(athleteData, for: Self.athleteKey)
        }
        if let curveData, let list = try? PowerCurve.decodeAll(curveData) {
            curves = RiderCard.byPeriod(list)
            cache.write(curveData, for: Self.curvesKey)
        }
        if let totalsData, let list = try? JSONDecoder().decode([ActivitySummary].self, from: totalsData) {
            totals = SeasonTotals(list, year: Self.year)
            cache.write(totalsData, for: Self.totalsKey)
        }
        lastError = (athleteData == nil && curveData == nil && totalsData == nil)
            ? "Couldn't reach Intervals. Showing what's saved." : nil
    }
}
