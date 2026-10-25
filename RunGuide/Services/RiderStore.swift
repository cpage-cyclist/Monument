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
            refit()
        }
        if let d = cache.read(Self.totalsKey)?.data, let list = try? JSONDecoder().decode([ActivitySummary].self, from: d) {
            totals = SeasonTotals(list, year: Self.year)
        }
    }

    /// Monument's profile from the last 90 days: OmPD where the curve allows, else 2-parameter CP.
    /// Worked out once per new set of curves.
    private(set) var monument: PowerProfile?

    private func refit() {
        monument = curves["90d"].flatMap { PowerProfile.fitBest(curve: $0) }
    }

    /// FTP for a source. Intervals' comes from the athlete settings, else the latest ride.
    func ftp(_ source: ThresholdSource, intervalsFallback: Double?) -> Double? {
        let intervals = athlete?.ride?.ftp ?? intervalsFallback
        switch source {
        case .intervals: return intervals
        case .monument: return monument?.ftp ?? intervals
        }
    }

    func wPrime(_ source: ThresholdSource) -> Double? {
        switch source {
        case .intervals: return athlete?.ride?.wPrime
        case .monument: return monument?.wPrime ?? athlete?.ride?.wPrime
        }
    }

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
            refit()
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
