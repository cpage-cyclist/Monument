import XCTest
@testable import RunGuideCore

final class RouteEffortsTests: XCTestCase {

    /// A straight 2 km route heading north.
    let route: Route = {
        let start = GeoPoint(lat: 51.40, lon: -0.20)
        let points = (0...20).map { i in GeoPoint(lat: start.lat + Double(i) * 100 / 111_195, lon: start.lon) }
        return Route(name: "Straight", points: points)
    }()

    /// A point `metres` north of the start.
    func at(_ metres: Double) -> GeoPoint {
        GeoPoint(lat: 51.40 + metres / 111_195, lon: -0.20)
    }

    // MARK: - Titles

    func testCommands() {
        XCTAssertEqual(RouteCommand(title: "GO"), .go(length: nil, target: nil, max: false))
        XCTAssertEqual(RouteCommand(title: "go 350w"),
                       .go(length: nil, target: PlanTarget(metric: .power, mode: .absolute, low: 350), max: false))
        XCTAssertEqual(RouteCommand(title: "GO 340-360W"),
                       .go(length: nil, target: PlanTarget(metric: .power, mode: .absolute, low: 340, high: 360), max: false))
        XCTAssertEqual(RouteCommand(title: "GO Z4"),
                       .go(length: nil, target: PlanTarget(metric: .power, mode: .zone, low: 4), max: false))
        XCTAssertEqual(RouteCommand(title: "GO 105%"),
                       .go(length: nil, target: PlanTarget(metric: .power, mode: .percent, low: 105), max: false))
        XCTAssertEqual(RouteCommand(title: "GO MAX"), .go(length: nil, target: nil, max: true))
        XCTAssertEqual(RouteCommand(title: "GO 5m 350W"),
                       .go(length: .time(300), target: PlanTarget(metric: .power, mode: .absolute, low: 350), max: false))
        XCTAssertEqual(RouteCommand(title: "GO 500m"), .go(length: .distance(500), target: nil, max: false))
        XCTAssertEqual(RouteCommand(title: "GO 2km"), .go(length: .distance(2000), target: nil, max: false))
        XCTAssertEqual(RouteCommand(title: "GO 4:00/km"),
                       .go(length: nil, target: PlanTarget(metric: .pace, mode: .absolute, low: 240), max: false))
        XCTAssertEqual(RouteCommand(title: "EASY"), .easy)
        XCTAssertEqual(RouteCommand(title: "end."), .easy)
        XCTAssertEqual(RouteCommand(title: "Stop"), .easy)
    }

    func testOrdinaryWaypointsAreIgnored() {
        XCTAssertNil(RouteCommand(title: "Easy climb"))
        XCTAssertNil(RouteCommand(title: "Go left at the pub"))
        XCTAssertNil(RouteCommand(title: "Café"))
        XCTAssertNil(RouteCommand(title: "End of the road"))
        XCTAssertNil(RouteCommand(title: ""))
    }

    // MARK: - Planning

    func testPlanFromStravaDistances() {
        let waypoints = [
            RouteWaypoint(title: "GO 5m 350W", lat: 0, lon: 0, distance: 1000),
            RouteWaypoint(title: "Café", lat: 0, lon: 0, distance: 600),
            RouteWaypoint(title: "GO Z4", lat: 0, lon: 0, distance: 200),
            RouteWaypoint(title: "EASY", lat: 0, lon: 0, distance: 700)
        ]
        let plan = RouteEfforts.plan(waypoints, route: route)
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0].number, 1)
        XCTAssertEqual(plan[0].start, 200)
        XCTAssertEqual(plan[0].stop, 700)
        XCTAssertNil(plan[0].length)
        XCTAssertEqual(plan[0].watts(ftp: 350)!.lowerBound, 318.5, accuracy: 0.01)   // Z4 is 91–105%
        XCTAssertNil(plan[0].watts(ftp: nil))
        XCTAssertEqual(plan[1].start, 1000)
        XCTAssertNil(plan[1].stop)
        XCTAssertEqual(plan[1].length, .time(300))
        XCTAssertEqual(plan[1].watts(ftp: nil), 350...350)
        XCTAssertEqual(plan[1].spoken, "5 minutes at 350 watts")
    }

    func testNextGoEndsTheOneBefore() {
        let plan = RouteEfforts.plan([
            RouteWaypoint(title: "GO", lat: 0, lon: 0, distance: 100),
            RouteWaypoint(title: "GO MAX", lat: 0, lon: 0, distance: 400),
            RouteWaypoint(title: "EASY", lat: 0, lon: 0, distance: 405)   // mis-tap: too short
        ], route: route)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].stop, 400)
        XCTAssertEqual(plan[0].spoken, "")
    }

    func testFileWaypointsSnapToTheLine() throws {
        let plan = RouteEfforts.plan([
            RouteWaypoint(title: "GO", lat: at(500).lat, lon: at(500).lon + 0.0003),   // ~20 m off the line
            RouteWaypoint(title: "EASY", lat: at(900).lat, lon: at(900).lon),
            RouteWaypoint(title: "GO", lat: 52, lon: 0)                                   // nowhere near
        ], route: route)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].start, 500, accuracy: 3)
        XCTAssertEqual(try XCTUnwrap(plan[0].stop), 900, accuracy: 3)
    }

    func testGPXWaypointsAreRead() throws {
        let gpx = """
        <?xml version="1.0"?>
        <gpx version="1.1"><wpt lat="51.40449" lon="-0.20"><name>GO 350W</name><desc>Hill</desc></wpt>
        <trk><name>Morning loop</name><trkseg>
        <trkpt lat="51.40" lon="-0.20"/><trkpt lat="51.41" lon="-0.20"/>
        </trkseg></trk></gpx>
        """
        let r = try RouteParser.parse(data: Data(gpx.utf8))
        XCTAssertEqual(r.name, "Morning loop")
        XCTAssertEqual(r.waypoints.count, 1)
        XCTAssertEqual(r.waypoints[0].title, "GO 350W")
        XCTAssertEqual(r.waypoints[0].note, "Hill")
        XCTAssertEqual(RouteEfforts.plan(r.waypoints, route: r).first?.start ?? 0, 500, accuracy: 5)
    }

    // MARK: - Playing

    /// Rides the route at 10 m/s, a fix a second, returning everything the player did and where.
    func ride(_ efforts: [RouteEffort], to end: Double = 1900) -> [(u: Double, event: EffortEvent)] {
        let guide = RouteGuide(route: route, loop: false)
        let player = RouteEffortPlayer(efforts: efforts, guide: guide, sport: .ride)
        var out: [(u: Double, event: EffortEvent)] = []
        let t0 = Date(timeIntervalSince1970: 0)
        var s = 0.0
        var second = 0.0
        while s <= end {
            let p = at(s)
            _ = guide.update(lat: p.lat, lon: p.lon, accuracy: 5, time: t0.addingTimeInterval(second))
            for e in player.update(time: second, speed: 10) { out.append((u: guide.progress ?? s, event: e)) }
            s += 10
            second += 1
        }
        return out
    }

    func testHeadsUpsCountdownStartAndEnd() {
        let effort = RouteEffort(number: 1, start: 800, stop: 1300, length: nil,
                                 target: PlanTarget(metric: .power, mode: .absolute, low: 350), max: false)
        let events = ride([effort])
        let said = events.compactMap { e -> (Double, String)? in
            if case .speak(let text, _) = e.event { return (e.u, text) } else { return nil }
        }
        XCTAssertEqual(said.map(\.1), ["Effort 1 in 500 metres, 350 watts.", "200 metres.", "3, 2, 1, go.",
                                       "Effort 1 done. Easy."])
        XCTAssertEqual(said[0].0, 300, accuracy: 10)
        XCTAssertEqual(said[1].0, 600, accuracy: 10)
        XCTAssertEqual(said[2].0, 770, accuracy: 10)
        let started = events.first { if case .started = $0.event { return true } else { return false } }
        let ended = events.first { if case .ended = $0.event { return true } else { return false } }
        XCTAssertEqual(started?.u ?? 0, 800, accuracy: 10)
        XCTAssertEqual(ended?.u ?? 0, 1300, accuracy: 10)
    }

    func testTimedEffortEndsOnTime() {
        let effort = RouteEffort(number: 1, start: 300, stop: nil, length: .time(30), target: nil, max: true)
        let events = ride([effort])
        let ended = events.first { if case .ended = $0.event { return true } else { return false } }
        XCTAssertEqual(ended?.u ?? 0, 600, accuracy: 15)   // 30 s at 10 m/s
        // Starting 300 m short of it: the real distance, then the 200 m mark.
        XCTAssertTrue(events.contains { $0.event == .speak("Effort 1 in 300 metres, 30 seconds all out.", urgent: true) })
        XCTAssertTrue(events.contains { $0.event == .speak("200 metres.", urgent: true) })
    }

    func testJoiningPastAnEffortSkipsIt() {
        // Start recording 50 m past where the effort began: dropped, not fired late.
        let guide = RouteGuide(route: route, loop: false)
        let effort = RouteEffort(number: 1, start: 50, stop: 500, length: nil, target: nil, max: false)
        let player = RouteEffortPlayer(efforts: [effort], guide: guide, sport: .ride)
        let p = at(100)
        _ = guide.update(lat: p.lat, lon: p.lon, accuracy: 5, time: Date())
        XCTAssertEqual(player.update(time: 0, speed: 10), [.skipped(effort)])
        XCTAssertNil(player.active)
    }
}
