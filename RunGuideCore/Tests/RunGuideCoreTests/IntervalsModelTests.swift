import XCTest
@testable import RunGuideCore

/// JSON below follows the raw Intervals.icu API shape, with values taken from real
/// activities (the 4×5 park ride and Parkrun in October 2026).
final class IntervalsModelTests: XCTestCase {

    func testActivityListDecodesRidesRunsAndStravaStubs() throws {
        let json = """
        [
          {"id": "i198230121", "start_date_local": "2026-10-17T08:33:50", "type": "Run",
           "name": "Parkrun", "description": "Fun parkrun", "moving_time": 2400, "distance": 7540.0,
           "total_elevation_gain": 69.5, "icu_training_load": 38, "icu_intensity": 71.5,
           "icu_rpe": 8, "feel": null, "source": "OAUTH_CLIENT"},
          {"id": 20617938250, "start_date_local": "2026-10-17T08:33:50", "source": "STRAVA"},
          {"id": "i196049903", "start_date_local": "2026-10-11T08:09:20", "type": "Ride",
           "name": "4 x 5", "moving_time": 7308, "distance": 58000.0, "icu_training_load": 112,
           "icu_weighted_avg_watts": 260, "icu_average_watts": 189, "average_cadence": 80.7,
           "icu_ftp": 350, "icu_rpe": 7, "feel": 2, "paired_event_id": 143985333}
        ]
        """
        let list = try JSONDecoder().decode([ActivitySummary].self, from: Data(json.utf8))
        XCTAssertEqual(list.count, 3)

        XCTAssertEqual(list[0].id.value, "i198230121")
        XCTAssertEqual(list[0].distance, 7540)
        XCTAssertNil(list[0].normalizedPower)
        XCTAssertTrue(list[0].isLogged)
        XCTAssertFalse(list[0].isStravaPlaceholder)

        XCTAssertEqual(list[1].id.value, "20617938250")
        XCTAssertTrue(list[1].isStravaPlaceholder)
        XCTAssertFalse(list[1].isLogged)

        XCTAssertEqual(list[2].normalizedPower, 260)
        XCTAssertEqual(list[2].ftp, 350)
        XCTAssertEqual(list[2].feel, 2)
        XCTAssertEqual(list[2].pairedEventId?.value, "143985333")

        let date = try XCTUnwrap(list[2].startDate)
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute], from: date)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute], [2026, 10, 11, 8, 9])
    }

    func testActivityDetailDecodesIntervals() throws {
        let json = """
        {"id": "i196049903", "type": "Ride", "name": "4 x 5", "moving_time": 7308,
         "icu_ftp": 350, "icu_max_wbal_depletion": 20659, "icu_joules_above_ftp": 71300,
         "stream_types": ["time", "watts", "cadence", "distance", "altitude", "latlng", "velocity_smooth"],
         "icu_intervals": [
           {"id": 2, "type": "WORK", "start_index": 3044, "end_index": 3342, "start_time": 3044,
            "end_time": 3343, "moving_time": 299, "distance": 3200, "average_watts": 369,
            "weighted_average_watts": 375, "max_watts": 574, "average_cadence": 87.6,
            "training_load": 9.5, "intensity": 105, "zone": 5, "wbal_start": 30999, "wbal_end": 17934},
           null,
           {"id": 3, "type": "RECOVERY", "start_time": 3343, "moving_time": 233, "average_watts": 129}
         ]}
        """
        let detail = try JSONDecoder().decode(ActivityDetail.self, from: Data(json.utf8))
        XCTAssertEqual(detail.summary.name, "4 x 5")
        XCTAssertEqual(detail.intervals.count, 2)
        XCTAssertEqual(detail.intervals[0].startIndex, 3044)
        XCTAssertEqual(detail.intervals[0].normalizedPower, 375)
        XCTAssertEqual(detail.intervals[0].wbalEnd, 17934)
        XCTAssertTrue(detail.intervals[0].isWork)
        XCTAssertFalse(detail.intervals[1].isWork)
        XCTAssertEqual(detail.maxWbalDepletion, 20659)
        XCTAssertFalse(detail.streamTypes.contains("heartrate"))
    }

    func testDetailWithoutIntervalsStillDecodes() throws {
        let json = #"{"id": "i1", "type": "Run"}"#
        let detail = try JSONDecoder().decode(ActivityDetail.self, from: Data(json.utf8))
        XCTAssertTrue(detail.intervals.isEmpty)
        XCTAssertTrue(detail.streamTypes.isEmpty)
    }

    func testStreamsDecodeWithGapsNullsAndNestedLatLng() throws {
        // A pause between 3 s and 60 s, a power dropout, a short HR stream and latlng.
        let json = """
        [
          {"type": "time", "data": [0, 1, 2, 3, 60, 61]},
          {"type": "fixed_watts", "data": [200, 210, null, 400, 380, 390]},
          {"type": "heartrate", "data": [120, 121, 122]},
          {"type": "latlng", "data": [[51.42, -0.21], [51.42, -0.21]]},
          {"type": "w_bal", "data": [31000, 31000, 31000, 30800, 30650, 30500]},
          {"type": "temp", "data": [9, 9, 9, 9, 9, 9]}
        ]
        """
        let s = try ActivityStreams.decode(Data(json.utf8))
        XCTAssertEqual(s.time, [0, 1, 2, 3, 60, 61])
        XCTAssertEqual(s.count, 6)

        // fixed_watts stands in for watts.
        XCTAssertEqual(s[.watts]?[1], 210)
        XCTAssertNil(s[.watts]?[2] ?? nil)
        XCTAssertNil(s[.fixedWatts])

        // Short streams are padded to the time stream's length.
        XCTAssertEqual(s[.heartrate]?.count, 6)
        XCTAssertNil(s[.heartrate]?[5] ?? nil)

        XCTAssertEqual(s[.wbal]?.last, 30500)
        XCTAssertTrue(s.has(.wbal))
        XCTAssertFalse(s.has(.cadence))
    }

    func testRealWattsWinOverFixedWatts() throws {
        let json = """
        [{"type": "time", "data": [0, 1]}, {"type": "watts", "data": [100, 101]},
         {"type": "fixed_watts", "data": [1, 1]}]
        """
        let s = try ActivityStreams.decode(Data(json.utf8))
        XCTAssertEqual(s[.watts]?.compactMap { $0 }, [100, 101])
    }

    func testLogBodiesClampAndSkipEmptyFields() {
        let log = ActivityLog(rpe: 12, feel: 0)
        XCTAssertEqual(log.body["icu_rpe"] as? Int, 10)
        XCTAssertEqual(log.body["feel"] as? Int, 1)
        XCTAssertNil(log.body["description"])

        XCTAssertEqual(ActivityLog.appending(note: " Legs heavy ", to: "Run Guide summary"),
                       "Run Guide summary\nLegs heavy")
        XCTAssertEqual(ActivityLog.appending(note: "Legs heavy", to: nil), "Legs heavy")
        XCTAssertNil(ActivityLog.appending(note: "  ", to: "kept"))

        let wellness = WellnessLog(sleepHours: 7.5, soreness: 5)
        XCTAssertEqual(wellness.body["sleepSecs"] as? Int, 27000)
        XCTAssertEqual(wellness.body["soreness"] as? Int, 4)
        XCTAssertNil(wellness.body["weight"])
        XCTAssertTrue(WellnessLog().isEmpty)
    }
}
