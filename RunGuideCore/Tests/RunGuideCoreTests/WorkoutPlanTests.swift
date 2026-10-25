import XCTest
@testable import RunGuideCore

/// Texts from the real Intervals library.
final class WorkoutPlanTests: XCTestCase {

    let abraRampSsen = """
    Warm Up
    - 15m 50-65%

    Blocks
    - 8m 89%
    - 8m 55%
    - 8m 92%
    - 8m 55%
    - 8m 95%
    - 8m 55%
    - 8m 98%
    - 8m 55%
    - 8m 101%
    - 8m 55%
    - 8m 104%
    - 8m 55%
    - 8m 107%
    - 8m 55%
    - 8m 110%

    Cool Down
    - 15m 50-65%
    """

    let engine = """
    Warm Up
    - 5m 50-60%
    - 5m Ramp 60-100%
    - 5m 50-60%

    8x
    - 30s 120-125%
    - 15s 90-95%

    - 5m z1-z2

    8x
    - 30s 120-125%
    - 15s 90-95%

    - 5m z1-z2

    8x
    - 30s 120-125%
    - 15s 90-95%

    - 5m z1-z2

    8x
    - 30s 120-125%
    - 15s 90-95%

    - 15m Z2
    """

    let hrFocus = "Controlled and on the pedals\n- 180m 70-73% HR"
    let parkrun = "- 3km 5:20/km Pace\n- 5km 4:20/km Pace\n- 3km 5:20/km Pace"
    let circuit = """
    Full Circuit x3 with 60s reco:

    Single-Leg RDL x 8-10 per side
    Push-Ups x 8-12 reps

    Notes:
    Keep 2-3 reps in reserve early on
    """

    // MARK: - Reading

    func testReadsNamedBlocks() {
        let plan = WorkoutPlan(text: abraRampSsen)
        XCTAssertEqual(plan.blocks.map(\.title), ["Warm Up", "Blocks", "Cool Down"])
        XCTAssertEqual(plan.blocks[1].steps.count, 15)
        XCTAssertEqual(plan.blocks[0].steps[0].target, PlanTarget(metric: .power, mode: .percent, low: 50, high: 65))
        XCTAssertEqual(plan.totalSeconds(), 150 * 60)
    }

    func testReadsRepeatsRampsAndZones() {
        let plan = WorkoutPlan(text: engine)
        XCTAssertEqual(plan.blocks.count, 9)
        XCTAssertEqual(plan.blocks[1].repeats, 8)
        XCTAssertEqual(plan.blocks[1].steps.count, 2)
        XCTAssertEqual(plan.blocks[0].steps[1].target,
                       PlanTarget(metric: .power, mode: .percent, low: 60, high: 100, ramp: true))
        XCTAssertEqual(plan.blocks[2].steps[0].target, PlanTarget(metric: .power, mode: .zone, low: 1, high: 2))
        XCTAssertEqual(plan.totalSeconds(), 69 * 60)
    }

    func testMinutesAreMinutesEvenOverAHundred() {
        let plan = WorkoutPlan(text: hrFocus)
        XCTAssertEqual(plan.blocks.first?.title, "Controlled and on the pedals")
        XCTAssertEqual(plan.blocks.first?.steps.first?.length, .time(3 * 3600))
        XCTAssertEqual(plan.blocks.first?.steps.first?.target,
                       PlanTarget(metric: .heartRate, mode: .percent, low: 70, high: 73))
        XCTAssertTrue(plan.notes.isEmpty)
    }

    func testReadsPaceDistances() {
        let plan = WorkoutPlan(text: parkrun, sport: "Run")
        let steps = plan.blocks.flatMap(\.steps)
        XCTAssertEqual(steps.map(\.length), [.distance(3000), .distance(5000), .distance(3000)])
        XCTAssertEqual(steps[1].target, PlanTarget(metric: .pace, mode: .absolute, low: 260))
        // Timed from the pace: 3 × 5:20 + 5 × 4:20 + 3 × 5:20.
        let expected: Double = 3 * 320 + 5 * 260 + 3 * 320
        XCTAssertEqual(plan.totalSeconds(), expected, accuracy: 0.001)
    }

    func testProseOnlyWorkoutKeepsItsNotes() {
        let plan = WorkoutPlan(text: circuit, sport: "Workout")
        XCTAssertTrue(plan.blocks.isEmpty)
        XCTAssertEqual(plan.notes, """
        Full Circuit x3 with 60s reco:

        Single-Leg RDL x 8-10 per side
        Push-Ups x 8-12 reps

        Notes:
        Keep 2-3 reps in reserve early on
        """)
        XCTAssertEqual(plan.text, plan.notes)
    }

    func testCadenceCueAndUnknownWordsSurvive() {
        let step = PlanStep(text: "Seated climb 6m 90% 70-75rpm freeride")
        XCTAssertEqual(step.cue, "Seated climb")
        XCTAssertEqual(step.length, .time(360))
        XCTAssertEqual(step.target, PlanTarget(metric: .power, mode: .percent, low: 90))
        XCTAssertEqual(step.cadence, CadenceRange(low: 70, high: 75))
        XCTAssertEqual(step.extra, "freeride")
        XCTAssertEqual(step.text, "Seated climb 6m 90% 70-75rpm freeride")
    }

    func testOtherTargets() {
        XCTAssertEqual(PlanStep(text: "5m 250w").target, PlanTarget(metric: .power, mode: .absolute, low: 250))
        XCTAssertEqual(PlanStep(text: "10m Z2 HR").target, PlanTarget(metric: .heartRate, mode: .zone, low: 2))
        XCTAssertEqual(PlanStep(text: "8m 95% LTHR").target, PlanTarget(metric: .lthr, mode: .percent, low: 95))
        XCTAssertEqual(PlanStep(text: "2km 80-85% Pace").target,
                       PlanTarget(metric: .pace, mode: .percent, low: 80, high: 85))
        XCTAssertEqual(PlanStep(text: "1km 4:50-5:00/km Pace").target,
                       PlanTarget(metric: .pace, mode: .absolute, low: 290, high: 300))
        XCTAssertEqual(PlanStep(text: "400mtr 3:40/km Pace").length, .distance(400))
        XCTAssertNil(PlanStep(text: "Easy by feel, RPE 3 20m").target)
        XCTAssertEqual(PlanStep(text: "Easy by feel, RPE 3 20m").cue, "Easy by feel, RPE 3")
    }

    // MARK: - Writing

    func testWritesBackTheSameText() {
        XCTAssertEqual(WorkoutPlan(text: abraRampSsen).text, abraRampSsen)
        XCTAssertEqual(WorkoutPlan(text: parkrun, sport: "Run").text, parkrun)
    }

    func testRoundTripKeepsMeaning() {
        for text in [engine, hrFocus, circuit] {
            let once = WorkoutPlan(text: text)
            XCTAssertEqual(WorkoutPlan(text: once.text), once, text)
        }
        XCTAssertEqual(WorkoutPlan(text: hrFocus).text, "Controlled and on the pedals\n- 3h 70-73% HR")
    }

    func testWritesEachKindOfStep() {
        let plan = WorkoutPlan(blocks: [
            PlanBlock(title: "Warmup", steps: [PlanStep(length: .time(600), target:
                PlanTarget(metric: .power, mode: .percent, low: 50, high: 75, ramp: true))]),
            PlanBlock(title: "Main set", repeats: 3, steps: [
                PlanStep(length: .time(720), target: PlanTarget(metric: .power, mode: .percent, low: 88, high: 94),
                         cadence: CadenceRange(low: 90)),
                PlanStep(length: .time(240), target: PlanTarget(metric: .power, mode: .zone, low: 1, high: 2))
            ]),
            PlanBlock(steps: [PlanStep(cue: "Spin out", length: .time(90))]),
            PlanBlock(repeats: 4, steps: [
                PlanStep(length: .distance(400), target: PlanTarget(metric: .pace, mode: .absolute, low: 225, high: 230)),
                PlanStep(length: .distance(1500), target: PlanTarget(metric: .heartRate, mode: .percent, low: 70))
            ])
        ])
        XCTAssertEqual(plan.text, """
        Warmup
        - 10m ramp 50-75%

        Main set 3x
        - 12m 88-94% 90rpm
        - 4m Z1-Z2

        - Spin out 1m30s

        4x
        - 400mtr 3:45-3:50/km Pace
        - 1.5km 70% HR
        """)
        XCTAssertEqual(WorkoutPlan(text: plan.text), plan)
    }

    // MARK: - Shape and load

    func testSegmentsExpandRepeatsAndRamps() {
        let plan = WorkoutPlan(text: "- 10m ramp 50-100%\n\n3x\n- 1m 120%\n- 1m 50%")
        let s = plan.segments()
        XCTAssertEqual(s.count, 7)
        XCTAssertEqual(s[0].from, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s[0].to, 1.0, accuracy: 1e-9)
        XCTAssertEqual(s[1].start, 600)
        XCTAssertEqual(s[6].end, 600 + 6 * 60)
    }

    func testLoadOfAnHourAtThresholdIsAHundred() {
        XCTAssertEqual(WorkoutPlan(text: "- 1h 100%").estimatedLoad(), 100, accuracy: 1e-9)
        XCTAssertEqual(WorkoutPlan(text: "- 1h 250w").estimatedLoad(PlanContext(ftp: 250)), 100, accuracy: 1e-9)
        // A 0–100% ramp averages a third of threshold-squared.
        XCTAssertEqual(WorkoutPlan(text: "- 1h ramp 0-100%").estimatedLoad(), 100.0 / 3, accuracy: 1e-9)
    }
}
