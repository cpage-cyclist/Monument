import XCTest
@testable import RunGuideCore

final class BestEffortsTests: XCTestCase {

    /// Sub-max efforts laid out per duration: `[duration][2nd, 3rd]`.
    private let perDuration = """
    {"list": [
      {"id": "1y", "secs": [5, 300, 1200], "values": [1400, 420, 360],
       "activity_id": ["i1", "i2", "i3"],
       "submax_values": [[1350, 1300], [410, 400], [355, 350]],
       "submax_activity_id": [["i4", "i5"], ["i6", "i7"], ["i2", "i8"]]},
      {"id": "all", "secs": [5, 300, 1200], "values": [1600, 450, 380],
       "activity_id": ["i9", "i2", "i10"],
       "submax_activity_id": [["i11", "i1"], ["i12", "i13"], ["i14", "i15"]]}
    ]}
    """

    /// The same, laid out per place: `[2nd at each duration], [3rd at each duration]`.
    private let perPlace = """
    {"list": [
      {"id": "1y", "secs": [5, 300, 1200], "values": [1400, 420, 360],
       "activity_id": ["i1", "i2", "i3"],
       "submax_activity_id": [["i4", "i6", "i2"], ["i5", "i7", "i8"]]}
    ]}
    """

    func testPlacesFromPerDurationLayout() throws {
        let ranks = BestEffortRanks(curves: try RankedCurve.decodeAll(Data(perDuration.utf8)))
        XCTAssertEqual(ranks.year?.place(of: "i1", at: 5), 1)
        XCTAssertEqual(ranks.year?.place(of: "i4", at: 5), 2)
        XCTAssertEqual(ranks.year?.place(of: "i5", at: 5), 3)
        XCTAssertEqual(ranks.year?.place(of: "i2", at: 1200), 2)
        XCTAssertNil(ranks.year?.place(of: "i99", at: 5))
        XCTAssertNil(ranks.year?.place(of: "i1", at: 60), "durations not on the curve have no place")
    }

    func testPlacesFromPerPlaceLayout() throws {
        let curve = try XCTUnwrap(RankedCurve.decodeAll(Data(perPlace.utf8)).first)
        XCTAssertEqual(curve.place(of: "i6", at: 300), 2)
        XCTAssertEqual(curve.place(of: "i7", at: 300), 3)
        XCTAssertEqual(curve.place(of: "i2", at: 1200), 2)
        XCTAssertEqual(curve.place(of: "i8", at: 1200), 3)
    }

    func testAllTimeOutranksYear() throws {
        let ranks = BestEffortRanks(curves: try RankedCurve.decodeAll(Data(perDuration.utf8)))
        // i2 is 1st this year at 5 min and 1st all time: all time wins.
        XCTAssertEqual(ranks.medal(activity: "i2", seconds: 300), EffortMedal(period: .allTime, place: 1))
        // i1 is best this year at 5 s, 3rd all time: all time still shown.
        XCTAssertEqual(ranks.medal(activity: "i1", seconds: 5), EffortMedal(period: .allTime, place: 3))
        // i4 only places this year.
        XCTAssertEqual(ranks.medal(activity: "i4", seconds: 5), EffortMedal(period: .year, place: 2))
        XCTAssertNil(ranks.medal(activity: "i99", seconds: 5))
    }

    func testCurvesMatchedByOrderWithoutIds() throws {
        let json = """
        [{"secs": [60], "activity_id": ["a"]}, {"secs": [60], "activity_id": ["b"]}]
        """
        let ranks = BestEffortRanks(curves: try RankedCurve.decodeAll(Data(json.utf8)))
        XCTAssertEqual(ranks.medal(activity: "a", seconds: 60), EffortMedal(period: .year, place: 1))
        XCTAssertEqual(ranks.medal(activity: "b", seconds: 60), EffortMedal(period: .allTime, place: 1))
    }

    func testDescription() {
        XCTAssertEqual(EffortMedal(period: .allTime, place: 1).description, "Best all time")
        XCTAssertEqual(EffortMedal(period: .year, place: 3).description, "3rd best this year")
    }
}
