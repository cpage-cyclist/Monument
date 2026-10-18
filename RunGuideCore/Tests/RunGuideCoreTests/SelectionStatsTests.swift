import XCTest
@testable import RunGuideCore

final class SelectionStatsTests: XCTestCase {

    /// 20 minutes at 1 Hz: 200 W, with a 5-minute block at 400 W from 600 s, steady 10 m/s,
    /// HR 150, cadence 90 with a coast, a 10 m hill, and W'bal dipping during the block.
    func makeRide() throws -> (ActivityStreams, Timeline) {
        let n = 1200
        let time = (0..<n).map(Double.init)
        let watts = (0..<n).map { i -> Double in (600..<900).contains(i) ? 400 : 200 }
        let cadence = (0..<n).map { i -> Double in (100..<110).contains(i) ? 0 : 90 }
        let altitude = (0..<n).map { i -> Double in i < 600 ? Double(i) / 60 : 10 }
        let wbal = (0..<n).map { i -> Double in (600..<900).contains(i) ? 31000 - Double(i - 600) * 50 : 31000 }
        func arr(_ v: [Double]) -> String { "[" + v.map { String($0) }.joined(separator: ",") + "]" }
        let json = """
        [{"type":"time","data":\(arr(time))},{"type":"watts","data":\(arr(watts))},
         {"type":"heartrate","data":\(arr(Array(repeating: 150, count: n)))},
         {"type":"cadence","data":\(arr(cadence))},
         {"type":"velocity_smooth","data":\(arr(Array(repeating: 10, count: n)))},
         {"type":"distance","data":\(arr(time.map { $0 * 10 }))},
         {"type":"altitude","data":\(arr(altitude))},
         {"type":"w_bal","data":\(arr(wbal))},
         {"type":"temp","data":\(arr(Array(repeating: 9, count: n)))}]
        """
        let streams = try ActivityStreams.decode(Data(json.utf8))
        return (streams, Timeline(time: streams.time))
    }

    func testSteadyBlockBreakdown() throws {
        let (streams, timeline) = try makeRide()
        let s = try XCTUnwrap(SelectionStats.compute(streams: streams, timeline: timeline, range: 600...899,
                                                     ftp: 400, weight: 75, isRun: false))
        XCTAssertEqual(s.duration, 299)
        XCTAssertEqual(try XCTUnwrap(s.distance), 2990, accuracy: 0.001)
        XCTAssertEqual(s.power, .init(min: 400, avg: 400, max: 400))
        XCTAssertEqual(try XCTUnwrap(s.normalizedPower), 400, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(s.intensity), 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(s.load), 299.0 / 3600 * 100, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(s.variabilityIndex), 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(s.work), 400 * 299 / 1000, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(s.wattsPerKg), 400.0 / 75, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(s.speed?.avg), 36, accuracy: 0.001)
        XCTAssertEqual(s.heartRate?.avg, 150)
        XCTAssertEqual(s.temperature?.max, 9)
        XCTAssertEqual(try XCTUnwrap(s.wbalStart), 31, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(s.wbalLow), 31 - 299 * 0.05, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(s.wbalUsed), 299 * 0.05, accuracy: 0.001)
        XCTAssertNil(s.decoupling)   // under 10 minutes
    }

    func testWholeRideClimbCoastingAndDecoupling() throws {
        let (streams, timeline) = try makeRide()
        let s = try XCTUnwrap(SelectionStats.compute(streams: streams, timeline: timeline, range: 0...1199,
                                                     ftp: 400, weight: nil, isRun: false))
        // Coasting zeros are left out of average and minimum cadence.
        XCTAssertEqual(s.cadence?.min, 90)
        XCTAssertEqual(try XCTUnwrap(s.elevationGain), 9, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(s.elevationLoss), 0, accuracy: 0.001)
        XCTAssertNotNil(s.vam)
        // NP is above average power because of the 400 W block.
        XCTAssertGreaterThan(try XCTUnwrap(s.normalizedPower), try XCTUnwrap(s.power?.avg))
        // Same HR, more power in the second half: negative decoupling.
        XCTAssertLessThan(try XCTUnwrap(s.decoupling), 0)
        XCTAssertNil(s.wattsPerKg)
    }

    func testShortSelectionsHaveNoNP() throws {
        let (streams, timeline) = try makeRide()
        let s = try XCTUnwrap(SelectionStats.compute(streams: streams, timeline: timeline, range: 10...20,
                                                     ftp: 400, weight: 75, isRun: false))
        XCTAssertEqual(s.normalizedPower, 200)   // falls back to average power
        XCTAssertNil(SelectionStats.compute(streams: streams, timeline: timeline, range: 5...5,
                                            ftp: 400, weight: 75, isRun: false))
    }

    func testRunPace() throws {
        let streams = try ActivityStreams.decode(Data("""
        [{"type":"time","data":[0,1,2,3,4]},{"type":"velocity_smooth","data":[3.33,3.33,4,2.5,3.33]},
         {"type":"distance","data":[0,3.33,7.33,9.83,13.16]}]
        """.utf8))
        let s = try XCTUnwrap(SelectionStats.compute(streams: streams, timeline: Timeline(time: streams.time),
                                                     range: 0...4, ftp: nil, weight: nil, isRun: true))
        XCTAssertEqual(try XCTUnwrap(s.pace?.min), 250, accuracy: 0.5)   // 4 m/s
        XCTAssertEqual(try XCTUnwrap(s.pace?.max), 400, accuracy: 0.5)   // 2.5 m/s
        XCTAssertEqual(try XCTUnwrap(s.pace?.avg), 4 / 13.16 * 1000, accuracy: 0.5)
        XCTAssertNil(s.power)
    }

    func testClimbIgnoresNoise() {
        let (gain, loss) = SelectionStats.climb([0, 0.5, 0, 0.5, 2, 1.5, 0])
        XCTAssertEqual(gain, 2)
        XCTAssertEqual(loss, 2)
    }

    func testPeaksFindTheBlock() throws {
        let (streams, timeline) = try makeRide()
        let peaks = PeakEffort.find(watts: try XCTUnwrap(streams[.watts]), timeline: timeline)
        // The ride is 1,199 recorded seconds, so 20m and 1h don't fit.
        XCTAssertEqual(peaks.map(\.label), ["5s", "15s", "1m", "5m", "10m"])
        let oneMin = try XCTUnwrap(peaks.first { $0.seconds == 60 })
        XCTAssertEqual(oneMin.watts, 400, accuracy: 0.001)
        XCTAssertTrue((600...899).contains(oneMin.range.lowerBound + 1))
        let ten = try XCTUnwrap(peaks.first { $0.seconds == 600 })
        XCTAssertLessThan(ten.watts, 400)
        XCTAssertGreaterThan(ten.watts, 200)
    }

    func testYDomainSnapsToData() {
        let pts = [ChartPoint(x: 0, y: 0), ChartPoint(x: 1, y: 115)]
        XCTAssertEqual(ChartKind.cadence.yDomain(for: pts).upperBound, 126.5, accuracy: 0.001)
        XCTAssertEqual(ChartKind.cadence.yDomain(for: pts).lowerBound, 0)
        let hr = [ChartPoint(x: 0, y: 120), ChartPoint(x: 1, y: 180)]
        XCTAssertEqual(ChartKind.heartRate.yDomain(for: hr).lowerBound, 114, accuracy: 0.001)
        XCTAssertEqual(ChartKind.heartRate.yDomain(for: hr).upperBound, 186, accuracy: 0.001)
    }
}
