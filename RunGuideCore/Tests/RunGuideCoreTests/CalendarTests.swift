import XCTest
@testable import RunGuideCore

final class CalendarTests: XCTestCase {

    /// Raw /events shape, with entries like the real calendar for 17–18 October 2026.
    let eventsJSON = """
    [
      {"id": 145117434, "start_date_local": "2026-10-17T00:00:00", "category": "WORKOUT", "type": "Ride",
       "name": "Threshold 3x12", "moving_time": 6960, "icu_training_load": 124, "icu_intensity": 80.1, "indoor": false,
       "description": "Threshold fitness: 3x12 min at 95-100% FTP.\\nSteady and seated.\\n\\nWarmup\\n- 15m ramp 55-75%\\n\\nMain set 3x\\n- Threshold 12m 95-100% 90rpm\\n- 5m 55%\\n\\nCooldown\\n- 10m 50%"},
      {"id": 145682854, "start_date_local": "2026-10-18T00:00:00", "category": "WORKOUT", "type": "Ride",
       "name": "Easy spin", "moving_time": 3600, "icu_training_load": 34},
      {"id": 145700001, "start_date_local": "2026-10-20T00:00:00", "category": "WORKOUT", "type": "Run",
       "name": "5x1km", "icu_training_load": 50},
      {"id": 145700002, "start_date_local": "2026-10-20T00:00:00", "category": "NOTE", "name": "Bike service"},
      {"id": 145700003, "start_date_local": "2026-10-25T00:00:00", "category": "RACE_B", "type": "Ride", "name": "Crit"}
    ]
    """

    let activitiesJSON = """
    [
      {"id": "i1", "start_date_local": "2026-10-17T09:00:00", "type": "Ride", "name": "Threshold", "moving_time": 6900,
       "icu_training_load": 120, "paired_event_id": 145117434},
      {"id": "i2", "start_date_local": "2026-10-17T17:00:00", "type": "Ride", "name": "Commute", "moving_time": 2000,
       "icu_training_load": 30},
      {"id": "20617938250", "start_date_local": "2026-10-17T08:33:50", "source": "STRAVA"}
    ]
    """

    func events() throws -> [CalendarEvent] { try JSONDecoder().decode([CalendarEvent].self, from: Data(eventsJSON.utf8)) }
    func activities() throws -> [ActivitySummary] { try JSONDecoder().decode([ActivitySummary].self, from: Data(activitiesJSON.utf8)) }

    func testDecodesEvents() throws {
        let e = try events()
        XCTAssertEqual(e.count, 5)
        XCTAssertEqual(e[0].day, "2026-10-17")
        XCTAssertEqual(e[0].trainingLoad, 124)
        XCTAssertTrue(e[0].isSession)
        XCTAssertTrue(e[2].isRun)
        XCTAssertTrue(e[3].isNote)
        XCTAssertFalse(e[3].isSession)
        XCTAssertTrue(e[4].isRace)
        XCTAssertTrue(e[4].isSession)
    }

    func testWindowIsThreeDaysEitherSide() throws {
        let date = try XCTUnwrap(IntervalsDates.parseLocal("2026-10-19T12:00:00"))
        let w = DayWindow(center: date)
        XCTAssertEqual(w.days, ["2026-10-16", "2026-10-17", "2026-10-18", "2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22"])
        XCTAssertEqual(w.shifted(byWeeks: 1).first, "2026-10-23")
        XCTAssertEqual(w.shifted(byWeeks: -1).center, "2026-10-12")
        // Across the end of British Summer Time (25 Oct).
        XCTAssertEqual(w.shifted(byWeeks: 1).days.count, 7)
        XCTAssertEqual(w.shifted(byWeeks: 1).last, "2026-10-29")
    }

    func testDayPlansPairPlannedAndDone() throws {
        let plans = DayPlan.build(days: ["2026-10-17", "2026-10-18", "2026-10-20"], events: try events(), activities: try activities())
        let sat = plans[0]
        XCTAssertEqual(sat.sessions.map(\.name), ["Threshold 3x12"])
        XCTAssertTrue(sat.isDone(sat.sessions[0]))
        XCTAssertEqual(sat.activities.map(\.id.value), ["i1", "i2"])   // Strava stub left out
        XCTAssertEqual(sat.unplannedActivities.map(\.id.value), ["i2"])
        XCTAssertEqual(sat.plannedLoad, 124)
        XCTAssertEqual(sat.completedLoad, 150)

        let sun = plans[1]
        XCTAssertFalse(sun.isDone(sun.sessions[0]))
        XCTAssertTrue(sun.activities.isEmpty)

        let tue = plans[2]
        XCTAssertEqual(tue.sessions.map(\.name), ["5x1km"])
        XCTAssertEqual(tue.notes.map(\.name), ["Bike service"])
    }

    func testNextSessionSkipsDoneAndPast() throws {
        let e = try events(), a = try activities()
        XCTAssertEqual(TodayPlan.next(events: e, activities: a, today: "2026-10-17")?.name, "Easy spin")
        XCTAssertEqual(TodayPlan.next(events: e, activities: a, today: "2026-10-19")?.name, "5x1km")
        XCTAssertEqual(TodayPlan.next(events: e, activities: a, today: "2026-10-21")?.name, "Crit")
        XCTAssertNil(TodayPlan.next(events: e, activities: a, today: "2026-10-26"))
    }

    func testFitnessAndForm() throws {
        let json = """
        [{"id": "2026-10-18", "ctl": 74.2, "atl": 71.7, "rampRate": -3.0},
         {"id": "2026-10-19", "ctl": 72.4, "atl": 62.1, "rampRate": -3.6},
         {"id": "2026-10-20", "ctl": null, "atl": null}]
        """
        let days = try JSONDecoder().decode([WellnessDay].self, from: Data(json.utf8))
        let today = try XCTUnwrap(WellnessDay.latest(in: days, onOrBefore: "2026-10-20"))
        XCTAssertEqual(today.id, "2026-10-19")
        XCTAssertEqual(try XCTUnwrap(today.form), 10.3, accuracy: 0.001)
    }

    func testStepOutlineDropsTheProse() throws {
        let e = try events()
        let lines = StepOutline.lines(e[0].description)
        XCTAssertEqual(lines.first, .init(text: "Warmup", isHeading: true))
        XCTAssertEqual(lines.map(\.text), ["Warmup", "15m ramp 55-75%", "Main set 3x", "Threshold 12m 95-100% 90rpm",
                                           "5m 55%", "Cooldown", "10m 50%"])
        XCTAssertTrue(StepOutline.lines("Just ride easy.").isEmpty)
        XCTAssertEqual(StepOutline.lines(String(repeating: "- 1m\n", count: 30), limit: 5).count, 5)
    }
}
