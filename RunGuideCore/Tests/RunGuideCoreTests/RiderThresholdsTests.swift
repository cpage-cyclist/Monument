import XCTest
@testable import RunGuideCore

final class RiderThresholdsTests: XCTestCase {

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
        XCTAssertEqual(r.map(\.activity), ["i8", "i9", "i7"])
    }

    func testIntervalsFTPIsTodaysSettingForEveryPeriod() {
        for p in RiderPeriod.allCases {
            XCTAssertEqual(RiderCard.thresholds(period: p, profiles: [:], currentFTP: 350).intervalsFTP, 350)
        }
    }

    func testMonumentFallsBackTo90d() {
        let p90 = PowerProfile(cp: 320, wPrime: 22000, method: "t", points: [:], r2: 1, from: nil, to: nil)
        let p1y = PowerProfile(cp: 330, wPrime: 23000, method: "t", points: [:], r2: 1, from: nil, to: nil)
        let profiles = ["90d": p90, "1y": p1y]
        let year = RiderCard.thresholds(period: .year, profiles: profiles, currentFTP: nil)
        XCTAssertEqual(year.monument?.cp, 330)
        XCTAssertFalse(year.monumentIs90d)
        let short = RiderCard.thresholds(period: .days42, profiles: profiles, currentFTP: nil)
        XCTAssertEqual(short.monument?.cp, 320)
        XCTAssertTrue(short.monumentIs90d)
    }

    func testWeighInsFromWellness() throws {
        let days = try JSONDecoder().decode([WellnessDay].self, from: Data("""
        [{"id": "2026-01-01", "ctl": 50, "atl": 40, "weight": 73},
         {"id": "2026-01-02", "ctl": 50, "atl": 40},
         {"id": "2026-01-03", "weight": 0}]
        """.utf8))
        XCTAssertEqual(RideThreshold.weighIns(days), ["2026-01-01": 73])
    }

    func testRideWeightsRunBetweenWeighIns() {
        // Rides stamped 78 by Intervals' default; weight runs in a line between weigh-ins.
        let stamped = [
            RideThreshold(activity: "before", day: "2019-06-01", ftp: 350, weight: 78),
            RideThreshold(activity: "on", day: "2020-01-01", ftp: 350, weight: 78),
            RideThreshold(activity: "mid", day: "2020-07-02", ftp: 350, weight: 78),
            RideThreshold(activity: "after", day: "2026-10-01", ftp: 350, weight: 78)
        ]
        let ins = ["2020-01-01": 72.0, "2021-01-01": 75.0]
        let w = RideThreshold.weights(stamped, weighIns: ins)
        XCTAssertEqual(w["before"], 72)
        XCTAssertEqual(w["on"], 72)
        XCTAssertEqual(w["mid"]!, 72 + 3 * 183.0 / 366, accuracy: 1e-9)   // 2020 is a leap year
        XCTAssertEqual(w["after"], 75)
        XCTAssertTrue(RideThreshold.weights(stamped, weighIns: [:]).isEmpty)
    }

    func testEffortWeightUsesItsRide() {
        let w = ["i1": 68.0]
        XCTAssertEqual(RiderCard.weight(for: RiderEffort(seconds: 5, watts: 1000, activity: "i1"), rideWeights: w, fallback: 70.5), 68)
        XCTAssertEqual(RiderCard.weight(for: RiderEffort(seconds: 5, watts: 1000, activity: "zz"), rideWeights: w, fallback: 70.5), 70.5)
        XCTAssertEqual(RiderCard.weight(for: nil, rideWeights: w, fallback: 70.5), 70.5)
    }
}
