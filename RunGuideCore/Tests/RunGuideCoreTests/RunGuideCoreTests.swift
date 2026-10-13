import XCTest
@testable import RunGuideCore

final class ParserTests: XCTestCase {

    let fiveByOne = """
    Warmup
    - 2km 5:00-5:30/km Pace

    Main set 5x
    - 1km 4:00/km Pace
    - Float 90s 5:00-5:30/km Pace

    Cooldown
    - 2km 5:00-5:30/km Pace
    """

    func testMixedDistanceAndTimeRepeats() {
        let w = WorkoutParser.parse(fiveByOne, name: "5x1km")
        XCTAssertEqual(w.steps.count, 12) // warmup + 5×2 + cooldown
        XCTAssertEqual(w.steps[0].label, "Warmup")
        XCTAssertEqual(w.steps[0].end, .distance(2000))
        XCTAssertEqual(w.steps[0].target, "5:00-5:30/km")
        XCTAssertEqual(w.steps[1].label, "Rep 1 of 5")
        XCTAssertEqual(w.steps[1].end, .distance(1000))
        XCTAssertEqual(w.steps[1].target, "4:00/km")
        XCTAssertEqual(w.steps[2].label, "Float")
        XCTAssertEqual(w.steps[2].end, .time(90))
        XCTAssertEqual(w.steps[9].label, "Rep 5 of 5")
        XCTAssertEqual(w.steps[11].label, "Cooldown")
        XCTAssertEqual(w.plannedDistance, 9000)
        XCTAssertEqual(w.plannedTime, 450)
    }

    func testCueTextAndNotesLine() {
        let text = """
        Test session: checking distance steps + narration on Wahoo.

        - Block 1 2.5km 4:35/km Pace
        - Block 2 2.5km 4:30/km Pace
        """
        let w = WorkoutParser.parse(text)
        XCTAssertEqual(w.steps.map(\.label), ["Block 1", "Block 2"])
        XCTAssertEqual(w.steps[0].end, .distance(2500))
    }

    func testAmounts() {
        XCTAssertEqual(WorkoutParser.parseAmount("10m"), .time(600))
        XCTAssertEqual(WorkoutParser.parseAmount("1m30s"), .time(90))
        XCTAssertEqual(WorkoutParser.parseAmount("1h30m"), .time(5400))
        XCTAssertEqual(WorkoutParser.parseAmount("400m"), .distance(400))
        XCTAssertEqual(WorkoutParser.parseAmount("400mtr"), .distance(400))
        XCTAssertEqual(WorkoutParser.parseAmount("2.5km"), .distance(2500))
        XCTAssertNil(WorkoutParser.parseAmount("4:00/km"))
        XCTAssertNil(WorkoutParser.parseAmount("Pace"))
        XCTAssertNil(WorkoutParser.parseAmount("1"))
    }

    func testRecoveryLabelWithoutCue() {
        let w = WorkoutParser.parse("3x\n- 400m 3:40/km\n- 60s\n")
        XCTAssertEqual(w.steps.map(\.label), ["Rep 1 of 3", "Recovery", "Rep 2 of 3", "Recovery", "Rep 3 of 3", "Recovery"])
    }
}

final class SpeechTests: XCTestCase {
    func testPhrases() {
        XCTAssertEqual(Speech.pace(240), "4 minutes")
        XCTAssertEqual(Speech.pace(298), "4 58")
        XCTAssertEqual(Speech.pace(245), "4 oh 5")
        XCTAssertEqual(Speech.target("4:00/km"), "4 minutes per kilometre")
        XCTAssertEqual(Speech.target("5:00-5:30/km"), "5 to 5 30 per kilometre")
        XCTAssertEqual(Speech.distance(1000), "1 kilometre")
        XCTAssertEqual(Speech.distance(2500), "2.5 kilometres")
        XCTAssertEqual(Speech.distance(400), "400 metres")
        XCTAssertEqual(Speech.duration(90), "90 seconds")
        XCTAssertEqual(Speech.duration(300), "5 minutes")
        XCTAssertEqual(Speech.duration(150), "2 minutes 30 seconds")
        XCTAssertEqual(Format.clock(2895), "48:15")
        XCTAssertEqual(Format.pace(298), "4:58")
    }
}

final class EngineTests: XCTestCase {

    /// Simulates running the session at a steady 4 m/s (4:10/km), one tick per second.
    func run(_ text: String, speed: Double = 4.0) -> (SessionEngine, [EngineEvent]) {
        let engine = SessionEngine(workout: WorkoutParser.parse(text, name: "Test"))
        var events = engine.start()
        var guardTicks = 0
        while !engine.finished && guardTicks < 20_000 {
            events += engine.advance(distance: speed, time: 1)
            guardTicks += 1
        }
        return (engine, events)
    }

    func testAutoLapsAcrossDistanceAndTimeSteps() {
        let text = """
        Warmup
        - 2km 5:00-5:30/km Pace

        Main set 5x
        - 1km 4:00/km Pace
        - Float 90s 5:00-5:30/km Pace

        Cooldown
        - 2km 5:00-5:30/km Pace
        """
        let (engine, events) = run(text)
        XCTAssertTrue(engine.finished)
        XCTAssertEqual(engine.laps.count, 12)
        XCTAssertEqual(engine.laps[0].distance, 2000, accuracy: 0.01)
        XCTAssertEqual(engine.laps[1].distance, 1000, accuracy: 0.01)
        XCTAssertEqual(engine.laps[1].duration, 250, accuracy: 0.01)
        XCTAssertEqual(engine.laps[2].duration, 90, accuracy: 0.01)
        XCTAssertEqual(engine.totalTime, engine.laps.reduce(0) { $0 + $1.duration }, accuracy: 0.01)

        let spoken = events.compactMap { e -> String? in if case .speak(let s) = e { return s }; return nil }
        XCTAssertTrue(spoken.first!.hasPrefix("Starting Test. Warmup. 2 kilometres at 5 to 5 30 per kilometre."))
        XCTAssertTrue(spoken.contains { $0.contains("Rep 2 of 5. 1 kilometre at 4 minutes per kilometre.") })
        XCTAssertTrue(spoken.contains { $0.hasPrefix("100 metres to go. Next, Float. 90 seconds") })
        XCTAssertTrue(spoken.contains { $0.hasPrefix("15 seconds. Next, Rep 2 of 5.") })
        XCTAssertTrue(spoken.contains { $0.contains("Rep 1 done, 4 10 per kilometre.") })
        XCTAssertTrue(spoken.contains { $0.hasPrefix("1 kilometre, 4 10 pace.") })
        XCTAssertTrue(spoken.last!.contains("Session complete."))
        XCTAssertEqual(events.last, .finished)
    }

    func testCountdownFiresOncePerStep() {
        let (_, events) = run("- 1km 4:00/km")
        let cues = events.filter { if case .speak(let s) = $0 { return s.hasPrefix("100 metres") }; return false }
        XCTAssertEqual(cues.count, 1)
    }

    func testManualLapAndEarlyFinish() {
        let engine = SessionEngine(workout: WorkoutParser.parse("- Easy\n- 5m\n"))
        _ = engine.start()
        _ = engine.advance(distance: 300, time: 100)
        XCTAssertEqual(engine.remaining, nil) // open step
        _ = engine.manualLap()
        XCTAssertEqual(engine.stepIndex, 1)
        _ = engine.advance(distance: 100, time: 30)
        let events = engine.finishEarly()
        XCTAssertTrue(engine.finished)
        XCTAssertEqual(engine.laps.count, 2)
        XCTAssertEqual(events.last, .finished)
    }
}
