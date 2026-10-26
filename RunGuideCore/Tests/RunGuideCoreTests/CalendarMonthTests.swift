import XCTest
@testable import RunGuideCore

final class CalendarMonthTests: XCTestCase {

    private func date(_ day: String) -> Date { IntervalsDates.parseLocal(day + "T12:00:00")! }

    // MARK: - Dates

    func testAddingDaysCrossesMonthsAndClockChange() {
        XCTAssertEqual(IntervalsDates.adding(1, to: "2026-10-31"), "2026-11-01")
        XCTAssertEqual(IntervalsDates.adding(-1, to: "2026-03-01"), "2026-02-28")
        // UK clocks go back on 25 October 2026.
        XCTAssertEqual(IntervalsDates.adding(1, to: "2026-10-25"), "2026-10-26")
        XCTAssertEqual(IntervalsDates.days(from: "2026-10-30", through: "2026-11-02"),
                       ["2026-10-30", "2026-10-31", "2026-11-01", "2026-11-02"])
        XCTAssertEqual(IntervalsDates.days(from: "2026-11-02", through: "2026-11-01"), [])
    }

    // MARK: - Month grid

    func testOctober2026StartsOnMondayBeforeThe1st() {
        // 1 October 2026 is a Thursday.
        let grid = MonthGrid(containing: date("2026-10-25"))
        XCTAssertEqual(grid.year, 2026)
        XCTAssertEqual(grid.month, 10)
        XCTAssertEqual(grid.weeks.count, 5)
        XCTAssertTrue(grid.weeks.allSatisfy { $0.count == 7 })
        XCTAssertEqual(grid.first, "2026-09-28")
        XCTAssertEqual(grid.last, "2026-11-01")
        XCTAssertTrue(grid.contains("2026-10-01"))
        XCTAssertFalse(grid.contains("2026-09-30"))
    }

    func testFebruaryThatFitsFourWeeks() {
        // 1 February 2027 is a Monday and the month has 28 days.
        let grid = MonthGrid(containing: date("2027-02-10"))
        XCTAssertEqual(grid.weeks.count, 4)
        XCTAssertEqual(grid.first, "2027-02-01")
        XCTAssertEqual(grid.last, "2027-02-28")
    }

    func testShiftingMonthsCrossesYears() {
        let grid = MonthGrid(containing: date("2026-12-15")).shifted(byMonths: 1)
        XCTAssertEqual(grid.prefix, "2027-01")
        XCTAssertEqual(MonthGrid(containing: date("2026-01-31")).shifted(byMonths: -1).prefix, "2025-12")
    }

    // MARK: - Projection

    func testStepMatchesExponentialAverage() {
        let k = 1 - exp(-1.0 / 42)
        XCTAssertEqual(FitnessProjection.step(60, load: 100, days: 42), 60 + 40 * k, accuracy: 1e-9)
        XCTAssertEqual(FitnessProjection.step(60, load: 60, days: 42), 60, accuracy: 1e-9)
    }

    func testRestDecaysFitnessAndFatigue() {
        let history = [WellnessDay(id: "2026-10-25", ctl: 70, atl: 90)]
        let days = FitnessProjection.project(history: history, planned: [:], completed: [:],
                                             today: "2026-10-25", through: "2026-10-28")
        XCTAssertEqual(days.map(\.id), ["2026-10-26", "2026-10-27", "2026-10-28"])
        XCTAssertEqual(days[0].ctl!, 70 * exp(-1.0 / 42), accuracy: 1e-9)
        XCTAssertEqual(days[0].atl!, 90 * exp(-1.0 / 7), accuracy: 1e-9)
        // Fatigue drops faster, so form rises.
        XCTAssertLessThan(days[0].form!, days[2].form!)
    }

    func testPlannedLoadForTodayRecomputesTodayFromYesterday() {
        let history = [WellnessDay(id: "2026-10-24", ctl: 70, atl: 80),
                       WellnessDay(id: "2026-10-25", ctl: 68.3, atl: 70.1)]
        let days = FitnessProjection.project(history: history, planned: ["2026-10-25": 100], completed: ["2026-10-25": 20],
                                             today: "2026-10-25", through: "2026-10-26")
        XCTAssertEqual(days.first?.id, "2026-10-25")
        XCTAssertEqual(days[0].ctl!, FitnessProjection.step(70, load: 120, days: 42), accuracy: 1e-9)
        XCTAssertEqual(days[0].atl!, FitnessProjection.step(80, load: 120, days: 7), accuracy: 1e-9)
    }

    func testNothingPlannedTodayKeepsIntervalsFigure() {
        let history = [WellnessDay(id: "2026-10-24", ctl: 70, atl: 80),
                       WellnessDay(id: "2026-10-25", ctl: 68.3, atl: 70.1)]
        let days = FitnessProjection.project(history: history, planned: ["2026-10-26": 50], completed: [:],
                                             today: "2026-10-25", through: "2026-10-26")
        XCTAssertEqual(days.map(\.id), ["2026-10-26"])
        XCTAssertEqual(days[0].ctl!, FitnessProjection.step(68.3, load: 50, days: 42), accuracy: 1e-9)
    }

    func testGapBeforeTodayUsesCompletedLoad() {
        let history = [WellnessDay(id: "2026-10-22", ctl: 50, atl: 50)]
        let days = FitnessProjection.project(history: history, planned: [:], completed: ["2026-10-23": 50],
                                             today: "2026-10-24", through: "2026-10-24")
        XCTAssertEqual(days.map(\.id), ["2026-10-23", "2026-10-24"])
        XCTAssertEqual(days[0].ctl!, 50, accuracy: 1e-9)
    }

    func testNoHistoryProjectsNothing() {
        XCTAssertTrue(FitnessProjection.project(history: [], planned: ["2026-10-26": 80], completed: [:],
                                                today: "2026-10-25", through: "2026-11-01").isEmpty)
    }

    func testPlannedLoadsSkipDoneAndPastSessions() throws {
        let events = try JSONDecoder().decode([CalendarEvent].self, from: Data("""
        [
          {"id": 1, "start_date_local": "2026-10-24T00:00:00", "category": "WORKOUT", "icu_training_load": 90},
          {"id": 2, "start_date_local": "2026-10-25T00:00:00", "category": "WORKOUT", "icu_training_load": 60},
          {"id": 3, "start_date_local": "2026-10-26T00:00:00", "category": "WORKOUT", "icu_training_load": 40},
          {"id": 4, "start_date_local": "2026-10-26T00:00:00", "category": "RACE_A", "icu_training_load": 150},
          {"id": 5, "start_date_local": "2026-10-26T00:00:00", "category": "NOTE", "icu_training_load": 999}
        ]
        """.utf8))
        let activities = try JSONDecoder().decode([ActivitySummary].self, from: Data("""
        [{"id": "i9", "start_date_local": "2026-10-25T08:00:00", "icu_training_load": 58, "paired_event_id": 2}]
        """.utf8))
        let planned = FitnessProjection.plannedLoads(events: events, activities: activities, from: "2026-10-25")
        XCTAssertEqual(planned, ["2026-10-26": 190])
        XCTAssertEqual(FitnessProjection.completedLoads(activities), ["2026-10-25": 58])
    }

    func testPairingOnADay() throws {
        let events = try JSONDecoder().decode([CalendarEvent].self, from: Data("""
        [
          {"id": 1, "start_date_local": "2026-10-25T00:00:00", "category": "WORKOUT", "name": "Threshold"},
          {"id": 2, "start_date_local": "2026-10-25T00:00:00", "category": "WORKOUT", "name": "Easy"}
        ]
        """.utf8))
        let activities = try JSONDecoder().decode([ActivitySummary].self, from: Data("""
        [
          {"id": "i1", "start_date_local": "2026-10-25T08:00:00", "paired_event_id": 1},
          {"id": "i2", "start_date_local": "2026-10-25T17:00:00"}
        ]
        """.utf8))
        let plan = DayPlan.build(days: ["2026-10-25"], events: events, activities: activities)[0]
        XCTAssertEqual(plan.activity(pairedWith: events[0])?.id.value, "i1")
        XCTAssertNil(plan.activity(pairedWith: events[1]))
        XCTAssertEqual(plan.unpairedSessions.map(\.id), [2])
        XCTAssertEqual(plan.unplannedActivities.map(\.id.value), ["i2"])
    }

    func testWeekTotals() throws {
        let events = try JSONDecoder().decode([CalendarEvent].self, from: Data("""
        [
          {"id": 1, "start_date_local": "2026-10-19T00:00:00", "category": "WORKOUT", "icu_training_load": 100},
          {"id": 2, "start_date_local": "2026-10-21T00:00:00", "category": "WORKOUT", "icu_training_load": 60},
          {"id": 3, "start_date_local": "2026-10-25T00:00:00", "category": "RACE_B", "icu_training_load": 150},
          {"id": 4, "start_date_local": "2026-10-22T00:00:00", "category": "NOTE"}
        ]
        """.utf8))
        let activities = try JSONDecoder().decode([ActivitySummary].self, from: Data("""
        [
          {"id": "a", "start_date_local": "2026-10-19T09:00:00", "moving_time": 5400, "distance": 45000,
           "total_elevation_gain": 500, "icu_training_load": 95, "paired_event_id": 1},
          {"id": "b", "start_date_local": "2026-10-23T17:00:00", "moving_time": 1800, "distance": 5000,
           "icu_training_load": 25}
        ]
        """.utf8))
        let grid = MonthGrid(containing: IntervalsDates.parseLocal("2026-10-22T12:00:00")!)
        let week = try XCTUnwrap(grid.week(containing: "2026-10-22"))
        XCTAssertEqual(week.first, "2026-10-19")
        XCTAssertEqual(week.last, "2026-10-25")
        let t = WeekTotals(DayPlan.build(days: week, events: events, activities: activities))
        XCTAssertEqual(t.plannedLoad, 310)
        XCTAssertEqual(t.doneLoad, 120)
        XCTAssertEqual(t.plannedSessions, 3)
        XCTAssertEqual(t.doneSessions, 1)
        XCTAssertEqual(t.seconds, 7200)
        XCTAssertEqual(t.metres, 50000)
        XCTAssertEqual(t.climbing, 500)
        XCTAssertEqual(t.activities, 2)
    }
}

final class WeekFitnessTests: XCTestCase {
    private let week = IntervalsDates.days(from: "2026-10-26", through: "2026-11-01")

    func testRunsFromTheDayBeforeToTheProjectedSunday() throws {
        let history = [WellnessDay(id: "2026-10-24", ctl: 80, atl: 90),
                       WellnessDay(id: "2026-10-25", ctl: 82, atl: 110),
                       WellnessDay(id: "2026-10-26", ctl: 85, atl: 117)]
        let projection = [WellnessDay(id: "2026-10-26", ctl: 85, atl: 117),
                          WellnessDay(id: "2026-11-01", ctl: 89, atl: 120)]
        let f = try XCTUnwrap(WeekFitness(week: week, history: history, projection: projection, today: "2026-10-26"))
        XCTAssertEqual(f.startFitness, 82)
        XCTAssertEqual(f.endFitness, 89)
        XCTAssertEqual(f.change, 7)
        XCTAssertEqual(f.endForm, -31)
        XCTAssertEqual(f.endDay, "2026-11-01")
        XCTAssertTrue(f.projected)
    }

    func testAPastWeekIsNotProjected() throws {
        let history = [WellnessDay(id: "2026-10-25", ctl: 82, atl: 110),
                       WellnessDay(id: "2026-11-01", ctl: 84, atl: 100)]
        let f = try XCTUnwrap(WeekFitness(week: week, history: history, projection: [], today: "2026-11-05"))
        XCTAssertEqual(f.change, 2)
        XCTAssertFalse(f.projected)
    }

    func testNothingBeforeTheWeekGivesNil() {
        let history = [WellnessDay(id: "2026-10-27", ctl: 82, atl: 110)]
        XCTAssertNil(WeekFitness(week: week, history: history, projection: [], today: "2026-10-27"))
    }
}
