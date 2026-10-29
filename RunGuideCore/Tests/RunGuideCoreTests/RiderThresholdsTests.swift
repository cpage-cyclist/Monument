import XCTest
@testable import RunGuideCore

final class RiderThresholdsTests: XCTestCase {

    let rides = [
        RideThreshold(activity: "i1", day: "2024-06-01", ftp: 360, weight: 68),
        RideThreshold(activity: "i2", day: "2025-11-10", ftp: 340, weight: 71),
        RideThreshold(activity: "i3", day: "2026-03-01", ftp: 345, weight: 70),
        RideThreshold(activity: "i4", day: "2026-05-01", ftp: 345, weight: 69.5),
        RideThreshold(activity: "i5", day: "2026-10-20", ftp: 330, weight: 70.5)
    ]
    let today = IntervalsDates.parseLocal("2026-10-29T12:00:00")!

    func testRidesFromActivitiesSkipRunsAndPlaceholders() throws {
        let list = try JSONDecoder().decode([ActivitySummary].self, from: Data("""
        [
          {"id": "i9", "start_date_local": "2026-03-02T09:00:00", "type": "VirtualRide", "icu_ftp": 330, "icu_weight": 70},
          {"id": "i8", "start_date_local": "2026-03-01T09:00:00", "type": "Ride", "icu_ftp": 335},
          {"id": "r1", "start_date_local": "2026-03-01T07:00:00", "type": "Run", "icu_ftp": 300, "icu_weight": 70},
          {"id": "i7", "start_date_local": "2026-03-03T09:00:00", "type": "Ride"},
          {"id": "20617938250", "start_date_local": "2026-03-03T08:00:00", "source": "STRAVA"}
        ]
        """.utf8))
        let r = RideThreshold.rides(list)
        XCTAssertEqual(r.map(\.activity), ["i8", "i9"])
        XCTAssertEqual(RideThreshold.weights(r), ["i9": 70])
    }

    func testPeakTakesFirstRideAtHighestFTP() {
        XCTAssertEqual(RideThreshold.peak(rides, from: "2025-10-29")?.activity, "i3")
        XCTAssertEqual(RideThreshold.peak(rides, from: nil)?.activity, "i1")
        XCTAssertNil(RideThreshold.peak(rides, from: "2027-01-01"))
    }

    func testIntervalsFTPFollowsPeriod() {
        let curves = ["1y": PowerCurve(secs: [5], values: [1000], startDateLocal: "2025-10-30T00:00:00")]
        func t(_ p: RiderPeriod) -> RiderThresholds {
            RiderCard.thresholds(period: p, curves: curves, profiles: [:], currentFTP: 330, rides: rides, today: today)
        }
        XCTAssertEqual(t(.days42).intervalsFTP, 330)
        XCTAssertNil(t(.days42).intervalsFTPRide)
        XCTAssertEqual(t(.year).intervalsFTP, 345)
        XCTAssertEqual(t(.year).intervalsFTPRide?.weight, 70)
        XCTAssertEqual(t(.allTime).intervalsFTP, 360)
        XCTAssertEqual(t(.allTime).intervalsFTPRide?.weight, 68)
    }

    func testTodaysSettingWinsWhenHigher() {
        let t = RiderCard.thresholds(period: .year, curves: [:], profiles: [:], currentFTP: 350, rides: rides, today: today)
        XCTAssertEqual(t.intervalsFTP, 350)
        XCTAssertNil(t.intervalsFTPRide)
    }

    func testYearStartWithoutCurveDate() {
        XCTAssertEqual(RiderCard.startDay(.year, curve: nil, today: today), "2025-10-29")
        XCTAssertNil(RiderCard.startDay(.allTime, curve: nil, today: today))
    }

    func testMonumentFallsBackTo90d() {
        let p90 = PowerProfile(cp: 320, wPrime: 22000, method: "t", points: [:], r2: 1, from: nil, to: nil)
        let p1y = PowerProfile(cp: 330, wPrime: 23000, method: "t", points: [:], r2: 1, from: nil, to: nil)
        let profiles = ["90d": p90, "1y": p1y]
        let year = RiderCard.thresholds(period: .year, curves: [:], profiles: profiles, currentFTP: nil, rides: [], today: today)
        XCTAssertEqual(year.monument?.cp, 330)
        XCTAssertFalse(year.monumentIs90d)
        let short = RiderCard.thresholds(period: .days42, curves: [:], profiles: profiles, currentFTP: nil, rides: [], today: today)
        XCTAssertEqual(short.monument?.cp, 320)
        XCTAssertTrue(short.monumentIs90d)
    }

    func testEffortWeightUsesItsRide() {
        let w = RideThreshold.weights(rides)
        XCTAssertEqual(RiderCard.weight(for: RiderEffort(seconds: 5, watts: 1000, activity: "i1"), rideWeights: w, fallback: 70.5), 68)
        XCTAssertEqual(RiderCard.weight(for: RiderEffort(seconds: 5, watts: 1000, activity: "zz"), rideWeights: w, fallback: 70.5), 70.5)
        XCTAssertEqual(RiderCard.weight(for: nil, rideWeights: w, fallback: 70.5), 70.5)
    }
}
