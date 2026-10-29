import XCTest
@testable import RunGuideCore

final class EffortFeedbackTests: XCTestCase {

    let first: (Int) -> Int = { _ in 0 }

    func testEveryLineIsFreeOfNumbers() {
        let states: [FeedbackState] = [.under, .on, .over]
        let trends: [FeedbackTrend] = [.steady, .rising, .falling]
        var all: [String] = []
        for now in states {
            for trend in trends {
                all += FeedbackLines.lines(previous: nil, now: now, trend: trend)
                for prev in states { all += FeedbackLines.lines(previous: prev, now: now, trend: trend) }
            }
            for throughout in [true, false] {
                for i in 0..<3 { all.append(FeedbackLines.summary(now, throughout: throughout, pick: { _ in i })) }
            }
        }
        XCTAssertGreaterThan(Set(all).count, 30)
        for line in all {
            XCTAssertFalse(line.contains { $0.isNumber }, line)
            for word in ["good", "great", "bad", "too ", "halfway", "metres", "kilometre", "minute"] {
                XCTAssertFalse(line.lowercased().contains(word), "\(line) says \(word)")
            }
        }
    }

    func testShortBlocksOnlyGetTheMiddle() {
        let short = EffortFeedback(target: .power(300...320), length: .time(90))
        XCTAssertEqual(short.checkpoints, [0.5])
        XCTAssertFalse(short.summarises)
        let long = EffortFeedback(target: .power(300...320), length: .time(120))
        XCTAssertEqual(long.checkpoints, [0.25, 0.5, 0.75])
        XCTAssertTrue(long.summarises)
        // A 600 m rep at 4:00/km is about 2:24.
        XCTAssertEqual(EffortFeedback(target: .pace(235...245), length: .distance(600)).checkpoints.count, 3)
        XCTAssertEqual(EffortFeedback(target: .pace(235...245), length: .distance(400)).checkpoints, [0.5])
    }

    func testSingleTargetsGetABand() {
        XCTAssertEqual(FeedbackTarget.powerBand(350...350), .power((350 * 0.97)...(350 * 1.03)))
        XCTAssertEqual(FeedbackTarget.powerBand(330...360), .power(330...360))
        XCTAssertEqual(FeedbackTarget.paceBand(240...240), .pace(235...245))
    }

    func testTargetsForSteps() {
        let power = Step(id: 0, label: "Rep 1", end: .time(300), target: "350w", kind: .active, watts: 350...350)
        XCTAssertEqual(FeedbackTarget.forStep(power), .power((350 * 0.97)...(350 * 1.03)))
        let pace = Step(id: 1, label: "Rep 1", end: .distance(1000), target: "4:00-4:10/km Pace", kind: .active)
        XCTAssertEqual(FeedbackTarget.forStep(pace), .pace(240...250))
        let rest = Step(id: 2, label: "Recovery", end: .time(90), target: "150w", kind: .rest, watts: 150...150)
        XCTAssertNil(FeedbackTarget.forStep(rest))
        let ramp = Step(id: 3, label: "Ramp", end: .time(600), target: "ramp 200-300w", kind: .active, watts: 200...300)
        XCTAssertNil(FeedbackTarget.forStep(ramp))
        let hr = Step(id: 4, label: "Tempo", end: .time(600), target: "Z3 HR", kind: .active)
        XCTAssertNil(FeedbackTarget.forStep(hr))
    }

    func testPowerCheckpointsFollowOn() {
        let f = EffortFeedback(target: .powerBand(350...350), length: .time(300), pick: first)
        var said: [String] = []
        func ride(_ seconds: Int, at watts: Double) {
            for _ in 0..<seconds { if let line = f.add(seconds: 1, metres: 10, watts: watts) { said.append(line) } }
        }
        ride(75, at: 380)    // 25%: out hot
        ride(75, at: 330)    // 50%: average 355, in the band
        ride(75, at: 350)    // 75%: still in it
        ride(75, at: 350)
        XCTAssertEqual(said, ["Above target.", "Settled into the band.", "Still on target."])
        XCTAssertEqual(f.finish(), "On target overall.")   // not on target at 25%, so not "throughout"
    }

    func testTrendOnTarget() {
        let f = EffortFeedback(target: .power(340...360), length: .time(400), pick: first)
        var said: [String] = []
        for i in 0..<100 {
            if let line = f.add(seconds: 1, metres: 10, watts: i < 70 ? 342 : 362) { said.append(line) }
        }
        // Average about 348 (on), last 30 s at 362: building.
        XCTAssertEqual(said, ["On target, and building."])
    }

    func testPaceBelowTarget() {
        let f = EffortFeedback(target: .paceBand(240...240), length: .distance(1000), pick: first)
        var said: [String] = []
        for _ in 0..<70 {   // 4 m/s is 4:10/km, slower than 3:55–4:05
            if let line = f.add(seconds: 1, metres: 4, watts: nil) { said.append(line) }
        }
        XCTAssertEqual(said, ["Below target."])
    }

    func testNoPowerMeterMeansSilence() {
        let f = EffortFeedback(target: .power(300...320), length: .time(120), pick: first)
        for _ in 0..<120 { XCTAssertNil(f.add(seconds: 1, metres: 10, watts: nil)) }
        XCTAssertNil(f.finish())
    }
}
