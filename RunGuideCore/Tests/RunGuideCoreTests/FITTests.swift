import XCTest
@testable import RunGuideCore

final class FITTests: XCTestCase {

    static let fiveByOne = """
    Warmup
    - 2km 5:00-5:30/km Pace

    Main set 5x
    - 1km 4:00/km Pace
    - Float 90s 5:00-5:30/km Pace

    Cooldown
    - 2km 5:00-5:30/km Pace
    """

    /// Runs the 5×1 km session at 4 m/s with a 20 s pause, the way the app does:
    /// add the point for this second, then close any lap that ended on it.
    func simulatedRecording(heartRate: Bool, gps: Bool) -> ActivityRecording {
        let workout = WorkoutParser.parse(Self.fiveByOne, name: "5x1km")
        let engine = SessionEngine(workout: workout)
        let t0 = Date(timeIntervalSince1970: 1_792_000_000)
        let recorder = ActivityRecorder(name: workout.name, start: t0)
        _ = engine.start()

        var now = t0
        var lon = -0.2
        var tick = 0
        while !engine.finished && tick < 20_000 {
            tick += 1
            now = now.addingTimeInterval(1)
            if tick == 100 {
                recorder.pause(at: now)
                now = now.addingTimeInterval(20)
                recorder.resume(at: now)
            }
            let events = engine.advance(distance: 4, time: 1)
            lon += 4 / 69_450.0
            recorder.addPoint(TrackPoint(
                time: now,
                latitude: gps ? 51.42 : nil,
                longitude: gps ? lon : nil,
                altitude: gps ? 20 : nil,
                distance: engine.totalDistance,
                speed: gps ? 4 : nil,
                heartRate: heartRate ? 140 + tick % 20 : nil
            ))
            for case .lap(let lap) in events { recorder.closeLap(lap, at: now) }
        }
        return recorder.finish(at: now, totalDistance: engine.totalDistance, totalTimerTime: engine.totalTime)
    }

    func testRecorderCapturesTypedLapsAndPauses() {
        let recording = simulatedRecording(heartRate: true, gps: true)
        XCTAssertEqual(recording.laps.count, 12)
        XCTAssertEqual(recording.laps.first?.kind, .warmup)
        XCTAssertEqual(recording.laps[1].kind, .active)
        XCTAssertEqual(recording.laps[2].kind, .rest)
        XCTAssertEqual(recording.laps.last?.kind, .cooldown)
        XCTAssertEqual(recording.laps[1].trigger, .distance)
        XCTAssertEqual(recording.laps[2].trigger, .time)
        XCTAssertEqual(recording.laps.last?.trigger, .sessionEnd)
        XCTAssertEqual(recording.events.map(\.kind), [.start, .stop, .start, .stop])
        // The pause is in elapsed time but not timer time.
        XCTAssertEqual(recording.elapsedTime - recording.totalTimerTime, 20, accuracy: 1)
        XCTAssertEqual(recording.laps[0].elapsedTime - recording.laps[0].timerTime, 20, accuracy: 1)
        XCTAssertNotNil(recording.laps[1].averageHeartRate)
        XCTAssertEqual(recording.totalDistance, 9000 + 5 * 360, accuracy: 1)
    }

    func testFITStructureAndCRC() throws {
        let data = FITEncoder.encode(simulatedRecording(heartRate: true, gps: true), timeZone: TimeZone(identifier: "Europe/London")!)
        let bytes = [UInt8](data)
        XCTAssertEqual(bytes[0], 14)
        XCTAssertEqual(Array(bytes[8..<12]), Array(".FIT".utf8))
        let bodySize = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
        XCTAssertEqual(bodySize, bytes.count - 14 - 2)
        XCTAssertEqual(FITEncoder.crc(data.prefix(12)), UInt16(bytes[12]) | UInt16(bytes[13]) << 8)
        // A FIT file's CRC over itself including the trailing CRC is zero.
        XCTAssertEqual(FITEncoder.crc(data), 0)
    }

    func testSemicircles() {
        XCTAssertEqual(FITEncoder.semicircles(0), 0)
        XCTAssertEqual(FITEncoder.semicircles(90), 1 << 30)
        XCTAssertEqual(FITEncoder.semicircles(-90), UInt64(UInt32(bitPattern: -(1 << 30))))
        XCTAssertEqual(FITEncoder.semicircles(nil), 0x7FFF_FFFF)
    }

    /// Writes sample files for CI to check with Garmin's FIT SDK.
    func testWriteSampleFilesForValidation() throws {
        guard let dir = ProcessInfo.processInfo.environment["RUN_GUIDE_FIT_OUT"] else {
            throw XCTSkip("Set RUN_GUIDE_FIT_OUT to write sample FIT files")
        }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FITEncoder.encode(simulatedRecording(heartRate: true, gps: true))
            .write(to: url.appendingPathComponent("full.fit"))
        try FITEncoder.encode(simulatedRecording(heartRate: false, gps: false))
            .write(to: url.appendingPathComponent("no-gps-no-hr.fit"))
    }
}
