import XCTest
@testable import RunGuideCore

final class RiderTests: XCTestCase {

    let curvesJSON = """
    {"list": [
      {"id": "42d", "secs": [5, 60, 300, 1200], "values": [1050, 520, 360, 310], "activity_id": ["i1", "i2", "i3", null]},
      {"id": "90d", "secs": [180, 300, 600, 1200], "values": [400, 370, 340, 315]},
      {"id": "1y", "secs": [5, 60, 300, 1200], "values": [1210, 560, 380, 322], "activity_id": ["i9", "i2", "i8", "i7"]},
      {"id": "all", "secs": [5, 60, 300, 1200], "values": [1350, 610, 420, 350]}
    ]}
    """

    func testCurvesByPeriodWithActivities() throws {
        let curves = try PowerCurve.decodeAll(Data(curvesJSON.utf8))
        let by = RiderCard.byPeriod(curves)
        XCTAssertEqual(Set(by.keys), ["42d", "90d", "1y", "all"])
        let efforts = RiderCard.efforts(by[RiderPeriod.year.curve])
        XCTAssertEqual(efforts.map(\.label), ["5s", "1m", "5m", "20m"])
        XCTAssertEqual(efforts.map(\.watts), [1210, 560, 380, 322])
        XCTAssertEqual(efforts[1].activity, "i2")
        XCTAssertNil(RiderCard.efforts(by["42d"])[3].activity)
        XCTAssertEqual(efforts[3].wattsPerKg(70)!, 4.6, accuracy: 1e-9)
        XCTAssertNil(efforts[3].wattsPerKg(nil))
    }

    func testCurvesWithoutIdsTakeRequestOrder() {
        let curves = (0..<4).map { PowerCurve(secs: [5], values: [Double($0)]) }
        XCTAssertEqual(RiderCard.byPeriod(curves)["1y"]?.values, [2])
    }

    func testVO2maxEstimate() {
        XCTAssertEqual(RiderCard.vo2max(fiveMinuteWatts: 350, weight: 70)!, 10.8 * 5 + 7, accuracy: 1e-9)
        XCTAssertNil(RiderCard.vo2max(fiveMinuteWatts: 350, weight: nil))
    }

    func testSeasonTotals() throws {
        let activities = try JSONDecoder().decode([ActivitySummary].self, from: Data("""
        [
          {"id": "a", "start_date_local": "2026-03-01T09:00:00", "type": "Ride", "moving_time": 7200,
           "distance": 60000, "total_elevation_gain": 800, "icu_training_load": 120},
          {"id": "b", "start_date_local": "2026-03-02T09:00:00", "type": "Run", "moving_time": 1800,
           "distance": 5000, "total_elevation_gain": 40, "icu_training_load": 30},
          {"id": "c", "start_date_local": "2025-12-31T09:00:00", "type": "Ride", "moving_time": 3600,
           "distance": 30000, "icu_training_load": 50},
          {"id": "20617938250", "start_date_local": "2026-03-03T08:00:00", "source": "STRAVA"}
        ]
        """.utf8))
        let t = SeasonTotals(activities, year: "2026")
        XCTAssertEqual(t.activities, 2)
        XCTAssertEqual(t.seconds, 9000)
        XCTAssertEqual(t.load, 150)
        XCTAssertEqual(t.rideMetres, 60000)
        XCTAssertEqual(t.climbing, 800)
    }

    func testAthleteProfileRideSettings() throws {
        let p = try JSONDecoder().decode(AthleteProfile.self, from: Data("""
        {"name": "Charles Page", "icu_weight": 70.5, "extra": 1,
         "sportSettings": [
           {"types": ["Run", "VirtualRun"], "ftp": null, "lthr": 172},
           {"types": ["Ride", "VirtualRide"], "ftp": 330, "w_prime": 24000, "lthr": 170, "max_hr": 192}
         ]}
        """.utf8))
        XCTAssertEqual(p.name, "Charles Page")
        XCTAssertEqual(p.weight, 70.5)
        XCTAssertEqual(p.ride?.ftp, 330)
        XCTAssertEqual(p.ride?.wPrime, 24000)
    }
}
