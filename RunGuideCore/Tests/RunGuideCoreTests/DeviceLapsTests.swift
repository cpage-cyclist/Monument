import XCTest
@testable import RunGuideCore

final class DeviceLapsTests: XCTestCase {

    private func encodedRun() -> Data {
        FITEncoder.encode(FITTests().simulatedRecording(heartRate: true, gps: true),
                          timeZone: TimeZone(identifier: "Europe/London")!)
    }

    func testReadsLapsBackFromFIT() throws {
        let laps = try FITLapReader.laps(from: encodedRun())
        XCTAssertEqual(laps.count, 12)
        XCTAssertEqual(laps[0].intensity, 2)   // warm-up
        XCTAssertEqual(laps[1].intensity, 0)   // active
        XCTAssertEqual(laps[2].intensity, 1)   // rest
        XCTAssertEqual(laps[11].intensity, 3)  // cool-down
        XCTAssertTrue(laps[2].isRest)
        XCTAssertEqual(laps[0].distance ?? 0, 2000, accuracy: 1)
        XCTAssertEqual(laps[1].distance ?? 0, 1000, accuracy: 1)
        // Laps run end to end, measured from the first sample.
        XCTAssertEqual(laps[0].startTime, 0, accuracy: 1.5)
        for i in 1..<laps.count {
            XCTAssertEqual(laps[i].startTime, laps[i - 1].endTime, accuracy: 1)
        }
        // The 20 s pause sits in the warm-up: elapsed is longer than timer time.
        XCTAssertEqual((laps[0].endTime - laps[0].startTime) - (laps[0].timerTime ?? 0), 20, accuracy: 1.5)
    }

    func testReadsGzippedFIT() throws {
        let fit = encodedRun()
        let deflated = try (fit as NSData).compressed(using: .zlib) as Data
        var gz = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
        gz.append(deflated)
        gz.append(Data(count: 8)) // CRC and size aren't checked
        XCTAssertEqual(try FITLapReader.laps(from: gz), try FITLapReader.laps(from: fit))
    }

    func testRejectsNonFIT() {
        XCTAssertThrowsError(try FITLapReader.laps(from: Data("<?xml version=\"1.0\"?><gpx/>".utf8)))
    }

    func testBuildsLapRowsFromStreams() {
        // 10 min ride: 5 min at 200 W, then 5 min at 300 W, lapped at 300 s.
        let time = (0..<600).map(Double.init)
        let watts: [Double?] = time.map { $0 < 300 ? 200 : 300 }
        let streams = ActivityStreams(time: time, series: [.watts: watts])
        let timeline = Timeline(time: time)
        let laps = [DeviceLap(startTime: 0, endTime: 300, timerTime: 300),
                    DeviceLap(startTime: 300, endTime: 599, timerTime: 299, intensity: 1)]
        let rows = DeviceLaps.intervals(laps, streams: streams, timeline: timeline, ftp: 300, weight: nil, isRun: false)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].label, "Lap 1")
        XCTAssertEqual(rows[0].averagePower ?? 0, 200, accuracy: 0.5)
        XCTAssertEqual(rows[1].averagePower ?? 0, 300, accuracy: 0.5)
        XCTAssertEqual(rows[0].movingTime, 300)
        XCTAssertTrue(rows[0].isWork)
        XCTAssertFalse(rows[1].isWork)
        XCTAssertEqual(rows[0].endIndex, 299)
        XCTAssertEqual(rows[1].startIndex, 300)
    }

    func testOnlyOneLapIsntWorthShowing() {
        XCTAssertFalse(DeviceLaps.useful(nil))
        XCTAssertFalse(DeviceLaps.useful([DeviceLap(startTime: 0, endTime: 3600)]))
        XCTAssertTrue(DeviceLaps.useful([DeviceLap(startTime: 0, endTime: 60), DeviceLap(startTime: 60, endTime: 120)]))
    }
}
