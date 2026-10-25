import XCTest
@testable import RunGuideCore

final class ChartDataTests: XCTestCase {

    func testTimelineCollapsesPauses() {
        // A 45-minute stop between 3 s and 2,703 s, like the 4×5 ride's café stop.
        let t = Timeline(time: [0, 1, 2, 3, 2703, 2704, 2709])
        XCTAssertEqual(t.x, [0, 1, 2, 3, 4, 5, 10])
        XCTAssertEqual(t.duration, 10)

        XCTAssertEqual(t.index(atX: 4.4), 4)
        XCTAssertEqual(t.index(atTime: 2700), 4)
        XCTAssertEqual(t.x(atTime: 2709), 10)
        XCTAssertEqual(t.index(atX: -5), 0)
        XCTAssertEqual(t.index(atX: 99), 6)
        XCTAssertNil(Timeline(time: []).index(atX: 1))
    }

    func testSmoothingIsATrailingAverageThatSkipsGaps() {
        let x: [Double] = [0, 1, 2, 3, 4]
        let y: [Double?] = [100, 200, nil, 300, 400]
        let s = ChartSeries.smoothed(y, x: x, window: 3)
        XCTAssertEqual(s[0], 100)
        XCTAssertEqual(s[1], 150)
        XCTAssertNil(s[2] ?? nil)
        XCTAssertEqual(s[3], 250)   // 200, (missing), 300
        XCTAssertEqual(s[4], 350)   // (missing), 300, 400
        XCTAssertEqual(ChartSeries.smoothed(y, x: x, window: 0).compactMap { $0 }, [100, 200, 300, 400])
    }

    func testDownsampleKeepsSpikes() {
        let n = 10_000
        let x = (0..<n).map(Double.init)
        var y = [Double?](repeating: 200, count: n)
        y[4321] = 1065      // a sprint
        y[7000] = 0         // a coast
        y[100] = nil

        let points = ChartSeries.downsample(x: x, y: y, maxPoints: 500)
        XCTAssertLessThanOrEqual(points.count, 500)
        XCTAssertTrue(points.contains(ChartPoint(x: 4321, y: 1065)))
        XCTAssertTrue(points.contains(ChartPoint(x: 7000, y: 0)))
        XCTAssertEqual(points.map(\.x), points.map(\.x).sorted())

        // Small series pass straight through, minus missing samples.
        XCTAssertEqual(ChartSeries.downsample(x: [0, 1, 2], y: [1, nil, 3], maxPoints: 500).count, 2)
    }

    func testPanelsAndUnitsForARideAndARun() throws {
        let ride = try ActivityStreams.decode(Data("""
        [{"type": "time", "data": [0, 1, 2]}, {"type": "watts", "data": [369, 402, 390]},
         {"type": "w_bal", "data": [31000, 30500, 17934]}, {"type": "cadence", "data": [88, 92, 90]},
         {"type": "velocity_smooth", "data": [10, 11, 12.5]}, {"type": "altitude", "data": [12, 13, 14]}]
        """.utf8))
        XCTAssertEqual(ChartKind.panels(for: ride, isRun: false), [.power, .wbal, .cadence, .speed, .altitude])
        XCTAssertEqual(try XCTUnwrap(ChartKind.wbal.values(from: ride).last ?? nil), 17.934, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(ChartKind.speed.values(from: ride).last ?? nil), 45, accuracy: 0.0001)

        let run = try ActivityStreams.decode(Data("""
        [{"type": "time", "data": [0, 1, 2]}, {"type": "velocity_smooth", "data": [2.82, 0.2, 3.33]},
         {"type": "altitude", "data": [20, 21, 22]}]
        """.utf8))
        XCTAssertEqual(ChartKind.panels(for: run, isRun: true), [.pace, .altitude])
        let pace = ChartKind.pace.values(from: run)
        XCTAssertEqual(ChartKind.pace.format(pace[0]), "5:55")
        XCTAssertNil(pace[1] ?? nil)   // standing still
        XCTAssertEqual(ChartKind.pace.format(pace[2]), "5:00")
        XCTAssertTrue(ChartKind.pace.reversed)
    }

    func testStackSmoothsOnlySmoothablePanels() throws {
        let streams = try ActivityStreams.decode(Data("""
        [{"type": "time", "data": [0, 1, 2, 3]}, {"type": "watts", "data": [0, 400, 0, 400]},
         {"type": "w_bal", "data": [31000, 30000, 30500, 29500]}]
        """.utf8))
        let stack = ChartStack(streams: streams, isRun: false, smoothing: .s3)
        let power = try XCTUnwrap(stack.panels.first { $0.kind == .power })
        let wbal = try XCTUnwrap(stack.panels.first { $0.kind == .wbal })
        XCTAssertEqual(power.value(at: 3) ?? 0, (400.0 + 0 + 400) / 3, accuracy: 0.001)
        XCTAssertEqual(wbal.value(at: 3), 29.5)
        XCTAssertNil(power.value(at: 99))
    }

    func testNormalisedOverlayScale() {
        XCTAssertEqual(ChartKind.power.normalized(250, in: 0...500), 0.5)
        XCTAssertEqual(ChartKind.power.value(atNormalized: 0.5, in: 0...500), 250)
        // Pace: faster (fewer seconds) sits higher.
        XCTAssertEqual(ChartKind.pace.normalized(240, in: 240...360), 1)
        XCTAssertEqual(ChartKind.pace.value(atNormalized: 1, in: 240...360), 240)
        XCTAssertEqual(ChartKind.heartRate.normalized(150, in: 150...150), 0.5)
    }
}
