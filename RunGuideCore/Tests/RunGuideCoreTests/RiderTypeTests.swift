import XCTest
@testable import RunGuideCore

final class RiderTypeTests: XCTestCase {

    func testScoreClampsToTable() {
        XCTAssertEqual(CogganProfile.score(seconds: 3600, wattsPerKg: 6.40), 1)
        XCTAssertEqual(CogganProfile.score(seconds: 3600, wattsPerKg: 1.0), 0)
        XCTAssertEqual(CogganProfile.score(seconds: 300, wattsPerKg: 9), 1)
        XCTAssertEqual(CogganProfile.score(seconds: 3600, wattsPerKg: 4.13)!, 0.5, accuracy: 1e-9)
        XCTAssertNil(CogganProfile.score(seconds: 1200, wattsPerKg: 4))
    }

    func testPursuiterWhenOneMinuteAndFiveMinuteLead() throws {
        // Roughly an all-time card: 1568 / 831 / 499 W and a 401 W FTP at ~72–75 kg.
        let c = try XCTUnwrap(CogganProfile.classify([5: 21.8, 60: 11.08, 300: 6.86, 3600: 5.57]))
        XCTAssertEqual(c.type, .pursuiter)
        XCTAssertEqual(c.lead, 60)
        XCTAssertEqual(c.leadLabel, "1 min")
        XCTAssertEqual(c.wattsPerKg, 11.08)
    }

    func testSprinterTimeTriallistAllRounder() throws {
        XCTAssertEqual(CogganProfile.classify([5: 22, 60: 8, 300: 4.5, 3600: 3.6])?.type, .sprinter)
        // 1 min peak with the sprint ahead of 5 min is still a sprinter.
        XCTAssertEqual(CogganProfile.classify([5: 20, 60: 10, 300: 4.5, 3600: 3.6])?.type, .sprinter)
        let tt = try XCTUnwrap(CogganProfile.classify([5: 14, 60: 7, 300: 5.5, 3600: 5.2]))
        XCTAssertEqual(tt.type, .timeTriallist)
        XCTAssertEqual(tt.leadLabel, "FTP")
        // Every duration at about the same place on the table.
        let flat = try XCTUnwrap(CogganProfile.classify([5: 17.7, 60: 8.57, 300: 4.97, 3600: 4.13]))
        XCTAssertEqual(flat.type, .allRounder)
        XCTAssertEqual(flat.lead, 3600)
    }

    func testNeedsAllFourDurations() {
        XCTAssertNil(CogganProfile.classify([5: 20, 60: 10, 300: 6]))
    }
}
