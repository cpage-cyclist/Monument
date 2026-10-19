import XCTest
@testable import RunGuideCore

final class WbalEffortsTests: XCTestCase {

    /// The 4×5 park ride's W'bal, averaged per minute (from Intervals, October 2026).
    let fourByFive: [Double?] = [31000.0, 31000.0, 31000.0, 31000.0, 30865.6, 30846.1, 30889.1, 30917.7, 30934.7, 30947.7, 30960.7, 30931.5, 30945.1, 30963.5, 30980.0, 30988.4, 30991.4, 30993.4, 30995.0, 30996.2, 30997.0, 30997.7, 30998.0, 30998.5, 30918.1, 30931.5, 30957.5, 30971.4, 30981.0, 30986.4, 30989.5, 30992.1, 30994.1, 30995.4, 30996.1, 30997.0, 30997.8, 30998.0, 30998.8, 30999.0, 30999.0, 30999.0, 30999.0, 30999.0, 30999.0, 30999.0, 30999.0, 30999.0, 30999.0, 30999.0, 30780.0, 28050.3, 24478.0, 23424.3, 20903.8, 18893.5, 20612.5, 24061.9, 26562.8, 27682.1, 24828.2, 22000.7, 18903.3, 14740.0, 11671.6, 16956.3, 21927.0, 24752.7, 26796.4, 25463.3, 22347.5, 21683.6, 19152.5, 16710.1, 18849.3, 22596.9, 25262.2, 27093.5, 28036.2, 23864.3, 21042.0, 18654.4, 15254.7, 11716.1, 18008.1, 23644.2, 26612.0, 28132.5, 29078.1, 29636.9, 29988.0, 30350.7, 30599.1, 30745.6, 30841.6, 30901.5, 30947.3, 30962.2, 30975.7, 30968.5, 30957.0, 30973.2, 30982.3, 30989.3, 30992.1, 30997.0, 30999.0, 30953.1, 30722.2, 30707.3, 30809.5, 30857.5, 30901.5, 30929.1, 30943.8, 30955.3, 30972.3, 30985.3, 30989.7, 30992.2, 30995.6, 30997.1, 30998.0, 30998.6, 30999.0]

    func testFindsTheFourRepsOfTheParkRide() throws {
        let a = try XCTUnwrap(WbalAnalysis.analyse(wbal: fourByFive))
        XCTAssertEqual(a.efforts.count, 4)
        XCTAssertEqual(a.efforts.map { ($0.spentKJ * 10).rounded() / 10 }, [11.9, 16.0, 10.1, 16.3])
        // The first effort starts where W'bal fell, not at the start of the flat top.
        XCTAssertEqual(a.efforts[0].startIndex, 50)
        XCTAssertEqual(a.efforts[0].endIndex, 55)
        XCTAssertEqual(a.lowIndex, 64)
        XCTAssertEqual(a.lowKJ, 11.6716, accuracy: 0.0001)
    }

    func testSmallWobblesAndMissingSamplesAreIgnored() throws {
        let a = try XCTUnwrap(WbalAnalysis.analyse(wbal: [31000, nil, 30000, 30800, 29500, 31000, nil]))
        XCTAssertTrue(a.efforts.isEmpty)
        XCTAssertEqual(a.lowIndex, 4)
        XCTAssertNil(WbalAnalysis.analyse(wbal: [nil, nil]))
    }

    func testEffortStillGoingAtTheEndIsCounted() throws {
        let a = try XCTUnwrap(WbalAnalysis.analyse(wbal: [31000, 31000, 25000, 20000, 15000]))
        XCTAssertEqual(a.efforts.count, 1)
        XCTAssertEqual(a.efforts[0].spentKJ, 16, accuracy: 0.001)
        XCTAssertEqual(a.efforts[0].startIndex, 1)
    }

    func testLabelledKeepsTheBiggestInTimeOrder() throws {
        let a = try XCTUnwrap(WbalAnalysis.analyse(wbal: fourByFive))
        let top2 = a.labelled(max: 2)
        XCTAssertEqual(top2.map(\.startIndex), [59, 78])
    }
}
