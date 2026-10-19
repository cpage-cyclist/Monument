import XCTest
@testable import RunGuideCore

final class PowerProfileTests: XCTestCase {

    /// Best efforts for the 90 days to the 4×5 park ride (14 Jul – 11 Oct 2026, from Intervals).
    let ninetyDays = PowerCurve(secs: [5, 60, 120, 180, 240, 300, 420, 600, 720, 900, 1200, 1800, 3600],
                                values: [1384, 831, 519, 456, 453, 432, 401, 390, 390, 382, 366, 327, 324],
                                startDateLocal: "2026-07-14T00:00:00", endDateLocal: "2026-10-11T00:00:00")

    func testFitsCriticalPowerToRealEfforts() throws {
        let p = try XCTUnwrap(PowerProfile.fitTwoParameter(curve: ninetyDays))
        XCTAssertEqual(p.cp, 351, accuracy: 1)
        XCTAssertEqual(p.wPrime / 1000, 23.1, accuracy: 0.2)
        XCTAssertEqual(p.points.count, 8)
        XCTAssertGreaterThan(p.r2, 0.99)
        XCTAssertEqual(p.from, "2026-07-14")
        XCTAssertEqual(p.to, "2026-10-11")
    }

    func testRejectsTooFewOrImplausibleEfforts() {
        XCTAssertNil(PowerProfile.fitTwoParameter(curve: PowerCurve(secs: [180, 300], values: [400, 380])))
        // Rising power with duration means no real efforts: nonsense, so no profile.
        XCTAssertNil(PowerProfile.fitTwoParameter(curve: PowerCurve(secs: [180, 300, 600, 1200], values: [100, 150, 200, 250])))
    }

    func testCurveInterpolatesAndDecodes() throws {
        let c = PowerCurve(secs: [180, 230, 250, 300], values: [450, 440, 430, 420])
        XCTAssertEqual(c.watts(at: 240), 435)
        XCTAssertNil(c.watts(at: 200))   // neighbours too far apart
        XCTAssertNil(c.watts(at: 600))
        let json = #"{"list": [{"secs": [1, 2], "values": [900, 880], "start_date_local": "2026-07-14T00:00:00"}]}"#
        let decoded = try XCTUnwrap(PowerCurve.decodeFirst(Data(json.utf8)))
        XCTAssertEqual(decoded.watts(at: 2), 880)
        XCTAssertEqual(try PowerCurve.decodeFirst(Data(#"[{"secs": [5], "watts": [1000]}]"#.utf8))?.watts(at: 5), 1000)
    }

    func testDifferentialWbal() throws {
        let model = WbalModel.skibaDifferential
        let cp = 350.0, wp = 20000.0
        // 100 s at 450 W drains 10 kJ exactly.
        let t = (0...100).map(Double.init)
        let hard = model.balance(watts: Array(repeating: 450, count: 101), time: t, cp: cp, wPrime: wp)
        XCTAssertEqual(try XCTUnwrap(hard.last ?? nil), 10000, accuracy: 0.001)

        // Riding at CP changes nothing.
        let atCP = model.balance(watts: Array(repeating: 350, count: 101), time: t, cp: cp, wPrime: wp)
        XCTAssertEqual(try XCTUnwrap(atCP.last ?? nil), wp)

        // After draining, easy riding refills towards (never past) W'.
        var watts: [Double?] = Array(repeating: 450, count: 101) + Array(repeating: 150, count: 600)
        watts[50] = nil   // a dropout counts as 0 W
        let time = (0..<watts.count).map(Double.init)
        let b = model.balance(watts: watts, time: time, cp: cp, wPrime: wp).compactMap { $0 }
        let low = try XCTUnwrap(b.min())
        XCTAssertLessThan(low, 11000)
        XCTAssertGreaterThan(b.last!, 19000)
        XCTAssertLessThanOrEqual(b.max()!, wp)
        // Recovery is fastest when furthest from full.
        XCTAssertGreaterThan(b[110] - b[100], b[690] - b[680])
    }

    func testStopsRefillW() throws {
        let model = WbalModel.skibaDifferential
        // Drain 10 kJ, then a 10-minute café stop.
        let watts: [Double?] = Array(repeating: 450, count: 101) + [0]
        let time: [Double] = (0...100).map { Double($0) } + [700.0]
        let b = model.balance(watts: watts, time: time, cp: 350, wPrime: 20000)
        let after = try XCTUnwrap(b.last ?? nil)
        // 10 kJ short, recovering at 0 W for 600 s: 20000 − 10000·e^(−350·600/20000).
        XCTAssertEqual(after, 20000 - 10000 * exp(-350.0 * 600 / 20000), accuracy: 1)
    }
}
