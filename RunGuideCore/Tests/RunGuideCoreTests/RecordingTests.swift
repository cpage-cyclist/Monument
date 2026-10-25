import XCTest
@testable import RunGuideCore

final class RecordingTests: XCTestCase {

    // MARK: - Bluetooth formats

    func testCyclingPowerWithCrankData() {
        // Flags 0x0020 (crank revolutions present), 250 W, 100 revs, event time 2048 (2 s).
        let data = Data([0x20, 0x00, 0xFA, 0x00, 0x64, 0x00, 0x00, 0x08])
        let r = CyclingPowerReading.parse(data)
        XCTAssertEqual(r?.watts, 250)
        XCTAssertEqual(r?.crank, CrankData(revolutions: 100, eventTime: 2048))
    }

    func testCyclingPowerSkipsEarlierOptionalFields() {
        // Balance (1 byte), torque (2), wheel (6) present before crank: flags 0x0035.
        let data = Data([0x35, 0x00, 0x2C, 0x01,
                         0x32,
                         0x10, 0x00,
                         0x01, 0x00, 0x00, 0x00, 0x00, 0x04,
                         0x0A, 0x00, 0x00, 0x04])
        let r = CyclingPowerReading.parse(data)
        XCTAssertEqual(r?.watts, 300)
        XCTAssertEqual(r?.crank, CrankData(revolutions: 10, eventTime: 1024))
    }

    func testCyclingPowerWithoutCrank() {
        XCTAssertEqual(CyclingPowerReading.parse(Data([0x00, 0x00, 0x96, 0x00])),
                       CyclingPowerReading(watts: 150, crank: nil))
        XCTAssertNil(CyclingPowerReading.parse(Data([0x00, 0x00])))
    }

    func testCSCCrankAfterWheelData() {
        let data = Data([0x03, 1, 0, 0, 0, 0, 0, 0x05, 0x00, 0x00, 0x02])
        XCTAssertEqual(CrankData.parseCSC(data), CrankData(revolutions: 5, eventTime: 512))
        XCTAssertNil(CrankData.parseCSC(Data([0x01, 1, 0, 0, 0, 0, 0])))
    }

    func testCadenceFromCrankEventsWithWrapAndCoasting() {
        var c = CadenceCalculator()
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertNil(c.update(CrankData(revolutions: 65534, eventTime: 64512), at: t0))
        // 3 revolutions in 2 s (2048 ticks, across both wraps) = 90 rpm.
        XCTAssertEqual(c.update(CrankData(revolutions: 1, eventTime: 1024), at: t0.addingTimeInterval(2)), 90)
        // Same event repeated: still 90 until 3 s pass, then 0.
        XCTAssertEqual(c.update(CrankData(revolutions: 1, eventTime: 1024), at: t0.addingTimeInterval(4)), 90)
        XCTAssertEqual(c.update(CrankData(revolutions: 1, eventTime: 1024), at: t0.addingTimeInterval(6)), 0)
    }

    func testRollingAverage() {
        var a = RollingAverage(seconds: 3)
        let t = Date(timeIntervalSince1970: 0)
        a.add(100, at: t)
        a.add(200, at: t.addingTimeInterval(1))
        a.add(300, at: t.addingTimeInterval(2))
        XCTAssertEqual(a.value(at: t.addingTimeInterval(2)), 200)
        a.add(400, at: t.addingTimeInterval(4))
        XCTAssertEqual(a.value(at: t.addingTimeInterval(4)), 300)
        XCTAssertNil(a.value(at: t.addingTimeInterval(10)))
    }

    // MARK: - Power maths

    func testNormalizedPower() {
        XCTAssertNil(PowerMath.normalized(Array(repeating: 200, count: 29)))
        XCTAssertEqual(PowerMath.normalized(Array(repeating: 200, count: 600)), 200)
        // Surges push NP above the average.
        let surges = (0..<600).map { ($0 / 60) % 2 == 0 ? 350 : 100 }
        let np = PowerMath.normalized(surges)!
        XCTAssertGreaterThan(np, PowerMath.average(surges)!)
    }

    func testWattsFromTargets() {
        XCTAssertEqual(PlanTarget(metric: .power, mode: .percent, low: 95, high: 100).watts(ftp: 300), 285...300)
        XCTAssertEqual(PlanTarget(metric: .power, mode: .absolute, low: 250).watts(ftp: 300), 250...250)
        XCTAssertEqual(PlanTarget(metric: .power, mode: .zone, low: 2).watts(ftp: 300), 168...225)
        XCTAssertNil(PlanTarget(metric: .heartRate, mode: .percent, low: 70).watts(ftp: 300))
    }

    // MARK: - Playing workouts

    func testWorkoutFromPlanUnrollsRepeatsWithWatts() {
        let plan = WorkoutPlan(text: """
        Warmup
        - 10m ramp 50-75%

        Main set 3x
        - 8m 95-100% 90rpm
        - 4m 55%

        - Spin out 3h
        """, name: "Threshold")
        let w = Workout(plan: plan, ftp: 300)
        XCTAssertEqual(w.name, "Threshold")
        XCTAssertEqual(w.steps.count, 1 + 6 + 1)
        XCTAssertEqual(w.steps[0].kind, .warmup)
        XCTAssertEqual(w.steps[0].watts, 150...225)
        XCTAssertEqual(w.steps[1].label, "Rep 1 of 3")
        XCTAssertEqual(w.steps[1].kind, .active)
        XCTAssertEqual(w.steps[1].target, "95-100% 90rpm")
        XCTAssertEqual(w.steps[2].label, "Recovery")
        XCTAssertEqual(w.steps[2].kind, .rest)
        // `m` is minutes, so a 3h step is three hours, not 3 metres or similar.
        XCTAssertEqual(w.steps[7].label, "Spin out")
        XCTAssertEqual(w.steps[7].end, .time(3 * 3600))
        XCTAssertEqual(w.plannedTime, 600 + 3 * 720 + 3 * 3600)
    }

    func testRunWorkoutFromPlanKeepsPaceTargets() {
        let w = Workout(plan: WorkoutPlan(text: "- 3km 5:20/km Pace", sport: "Run"), ftp: nil)
        XCTAssertEqual(w.steps.first?.end, .distance(3000))
        XCTAssertEqual(w.steps.first?.target, "5:20/km Pace")
        XCTAssertNil(w.steps.first?.watts)
        XCTAssertEqual(Speech.target("5:20/km Pace"), "5 20 per kilometre")
    }

    func testSpokenPowerTargets() {
        XCTAssertEqual(Speech.target("95-100%"), "95 to 100 percent")
        XCTAssertEqual(Speech.target("ramp 50-75%"), "ramping 50 to 75 percent")
        XCTAssertEqual(Speech.target("250w"), "250 watts")
        XCTAssertEqual(Speech.target("Z1-Z2"), "zone 1 to zone 2")
        XCTAssertEqual(Speech.speed(secondsPerKm: 120), "30 kilometres an hour")
    }

    func testRideSplitsEveryFiveKilometresWithSpeed() {
        let engine = SessionEngine(workout: .justRecord(.ride), options: EngineOptions(sport: .ride))
        _ = engine.start()
        var said: [String] = []
        for _ in 0..<1200 {
            for case .speak(let text) in engine.advance(distance: 10, time: 1) { said.append(text) }
        }
        XCTAssertEqual(said, ["5 kilometres, 36 kilometres an hour.", "10 kilometres, 36 kilometres an hour."])
    }

    func testFreeRecordingLapsWithoutEnding() {
        let engine = SessionEngine(workout: .justRecord(.run))
        _ = engine.start()
        _ = engine.advance(distance: 1000, time: 300)
        let first = engine.manualLap()
        XCTAssertFalse(engine.finished)
        var labels: [String] = []
        for case .lap(let l) in first { labels.append(l.label) }
        XCTAssertEqual(labels, ["Lap 1"])
        _ = engine.advance(distance: 500, time: 150)
        _ = engine.manualLap()
        XCTAssertEqual(engine.laps.map(\.distance), [1000, 500])
        XCTAssertEqual(engine.totalDistance, 1500)
        let end = engine.finishEarly()
        XCTAssertTrue(engine.finished)
        XCTAssertTrue(end.contains { if case .finished = $0 { true } else { false } })
    }

    func testSportSettings() {
        XCTAssertEqual(RecordSport.ride.routeHeadsUp, 500)
        XCTAssertEqual(RecordSport.run.routeHeadsUp, 100)
        XCTAssertTrue(RecordSport.ride.matches(intervalsType: "VirtualRide"))
        XCTAssertFalse(RecordSport.run.matches(intervalsType: "Ride"))
        XCTAssertEqual(RecordSport.ride.fitSport, 2)
    }

    // MARK: - Recording power

    /// An hour's ride in 1 s points: 10 min at 150 W, then 4 × (5 min at 300 W, 5 min at 150 W),
    /// 10 min at 150 W, 90 rpm with some coasting, a manual lap every 10 minutes.
    static func simulatedRide() -> ActivityRecording {
        let engine = SessionEngine(workout: .justRecord(.ride), options: EngineOptions(sport: .ride))
        let t0 = Date(timeIntervalSince1970: 1_792_000_000)
        let recorder = ActivityRecorder(name: "Ride", start: t0, sport: .ride)
        _ = engine.start()
        var now = t0
        var lon = -0.2
        for tick in 1...3600 {
            now = now.addingTimeInterval(1)
            let minute = (tick - 1) / 60
            let hard = minute >= 10 && minute < 50 && (minute - 10) % 10 < 5
            let coasting = tick % 120 < 5
            _ = engine.advance(distance: 9, time: 1)
            lon += 9 / 69_450.0
            recorder.addPoint(TrackPoint(time: now, latitude: 51.42, longitude: lon, altitude: 20,
                                         distance: engine.totalDistance, speed: 9, heartRate: 150,
                                         power: coasting ? 0 : (hard ? 300 : 150),
                                         cadence: coasting ? 0 : 90))
            if tick % 600 == 0, tick < 3600 {
                for case .lap(let lap) in engine.manualLap() { recorder.closeLap(lap, at: now) }
            }
        }
        for case .lap(let lap) in engine.finishEarly() { recorder.closeLap(lap, at: now) }
        return recorder.finish(at: now, totalDistance: engine.totalDistance, totalTimerTime: engine.totalTime)
    }

    func testRidePowerSummary() {
        let ride = Self.simulatedRide()
        XCTAssertEqual(ride.sport, .ride)
        XCTAssertEqual(ride.laps.count, 6)
        let p = ride.power
        XCTAssertEqual(p.max, 300)
        XCTAssertEqual(p.averageCadence, 90)
        XCTAssertNotNil(p.normalized)
        XCTAssertGreaterThan(p.normalized!, p.average!)
        XCTAssertEqual(ride.laps[1].power.max, 300)
    }

    func testRideFITIsValidStructure() throws {
        let data = FITEncoder.encode(Self.simulatedRide())
        XCTAssertEqual(Array(data[8..<12]), Array(".FIT".utf8))
        let crc = FITEncoder.crc(data.prefix(data.count - 2))
        XCTAssertEqual(UInt16(data[data.count - 2]) | UInt16(data[data.count - 1]) << 8, crc)
    }

    func testWriteRideSampleForValidation() throws {
        guard let dir = ProcessInfo.processInfo.environment["RUN_GUIDE_FIT_OUT"] else {
            throw XCTSkip("Set RUN_GUIDE_FIT_OUT to write sample FIT files")
        }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FITEncoder.encode(Self.simulatedRide()).write(to: url.appendingPathComponent("ride-power.fit"))
    }
}
