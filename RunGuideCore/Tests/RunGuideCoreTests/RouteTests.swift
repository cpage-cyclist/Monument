import XCTest
@testable import RunGuideCore

/// Tests against three real Strava route exports (in Routes/):
/// - loop-6.89km: loop starting up a short side road (shared stub)
/// - loop-8.45km: loop with lots of right-angle turns (also as TCX)
/// - point-to-point-16.05km: roads then park paths
final class RouteTests: XCTestCase {

    func load(_ name: String, _ ext: String = "gpx") throws -> Route {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Routes"),
                                "missing fixture \(name).\(ext)")
        return try RouteParser.parse(data: Data(contentsOf: url), fallbackName: name)
    }

    // MARK: - Parsing and turn detection

    func testParsesStravaFiles() throws {
        let loop = try load("loop-6.89km")
        XCTAssertEqual(loop.name, "6.89 km London Run Route")
        XCTAssertEqual(loop.length, 6900, accuracy: 60)
        XCTAssertTrue(loop.isLoop)

        let p2p = try load("point-to-point-16.05km")
        XCTAssertEqual(p2p.length, 16050, accuracy: 80)
        XCTAssertFalse(p2p.isLoop)

        // Named 5.97 km in Strava, but the line is 8.45 km.
        let gpx = try load("loop-8.45km")
        let tcx = try load("loop-8.45km", "tcx")
        XCTAssertEqual(gpx.length, 8448, accuracy: 60)
        XCTAssertEqual(tcx.length, gpx.length, accuracy: 5)
        XCTAssertEqual(tcx.turns.count, gpx.turns.count)
    }

    func testTurnsOnTheLoop() throws {
        let r = try load("loop-6.89km")
        XCTAssertTrue((10...13).contains(r.turns.count), "got \(r.turns.count) turns")
        // 1.18 km is a straight road with a kink in the line: no cue.
        XCTAssertFalse(r.turns.contains { (1100...1250).contains($0.at) }, "\(r.turns.map(\.at))")
        // 1.55 km sharp right.
        XCTAssertTrue(r.turns.contains { (1480...1620).contains($0.at) && $0.direction == .sharpRight })
        // 5.17 km cross-and-loop-back junction: one cue, flagged tricky.
        let tricky = r.turns.filter { (5080...5260).contains($0.at) }
        XCTAssertEqual(tricky.count, 1)
        XCTAssertEqual(tricky.first?.tricky, true)
    }

    func testRightAngleTurns() throws {
        let r = try load("loop-8.45km")
        XCTAssertGreaterThanOrEqual(r.turns.count, 22)
        let plain = r.turns.filter { $0.direction == .left || $0.direction == .right }
        XCTAssertGreaterThanOrEqual(plain.count, 20)
    }

    func testLoopJoin() throws {
        let stubbed = RouteGuide(route: try load("loop-6.89km"), loop: true)
        XCTAssertEqual(stubbed.loopStart, 70, accuracy: 30)
        XCTAssertEqual(stubbed.joinTurn?.direction, .right)

        let plain = RouteGuide(route: try load("loop-8.45km"), loop: true)
        XCTAssertEqual(plain.loopStart, 0, accuracy: 6)
        XCTAssertEqual(plain.joinTurn?.direction.isLeft, true)
    }

    // MARK: - Simulated runs

    struct Said {
        let at: Double
        let text: String
    }

    /// Runs the course at 4 m/s with a fix every second. `offset` lets a test
    /// push the runner sideways (metres east) at chosen distances.
    func simulate(_ guide: RouteGuide, laps: Int = 1,
                  offset: (Double) -> Double = { _ in 0 }) -> [Said] {
        let r = guide.route
        var course: [Double] = []
        if guide.looping {
            course += stride(from: 0.0, to: guide.loopEnd, by: 4).map { $0 }
            for _ in 1..<max(1, laps) {
                course += stride(from: guide.loopStart, to: guide.loopEnd, by: 4).map { $0 }
            }
        } else {
            course = stride(from: 0.0, through: r.length, by: 4).map { $0 }
        }
        var said: [Said] = []
        var t = Date(timeIntervalSince1970: 1_800_000_000)
        for (k, d) in course.enumerated() {
            var p = r.point(at: d)
            let east = offset(Double(k) * 4)
            p.lon += east / (111_320 * cos(p.lat * .pi / 180))
            for text in guide.update(lat: p.lat, lon: p.lon, accuracy: 5, time: t) {
                said.append(Said(at: Double(k) * 4, text: text))
            }
            t = t.addingTimeInterval(1)
        }
        return said
    }

    func testRunThePointToPointRoute() throws {
        let guide = RouteGuide(route: try load("point-to-point-16.05km"), loop: false)
        let said = simulate(guide)
        let nows = said.filter { $0.text.hasSuffix(" now.") }
        XCTAssertEqual(nows.count, guide.route.turns.count, said.map(\.text).joined(separator: " | "))
        XCTAssertFalse(said.contains { $0.text == "Off route." })
        XCTAssertEqual(said.last?.text, "End of route.")
        // Every heads-up comes before its "now".
        XCTAssertTrue(said.contains { $0.text.hasPrefix("In 100 metres, ") })
    }

    func testRunTheLoopWithACrossover() throws {
        // The 6.89 km loop passes close to itself around 3.2 km and 5.2 km;
        // forward tracking must not jump between the two.
        let guide = RouteGuide(route: try load("loop-6.89km"), loop: false)
        let said = simulate(guide)
        XCTAssertFalse(said.contains { $0.text == "Off route." }, said.map(\.text).joined(separator: " | "))
        XCTAssertEqual(said.filter { $0.text.hasSuffix(" now.") }.count, guide.route.turns.count)
        XCTAssertTrue(said.contains { $0.text == "Sharp right now." })
        XCTAssertTrue(said.contains { $0.text.hasPrefix("Tricky junction") })
        XCTAssertEqual(said.last?.text, "End of route.")
    }

    func testLapsOnTheLoop() throws {
        let guide = RouteGuide(route: try load("loop-6.89km"), loop: true)
        let said = simulate(guide, laps: 3)
        let texts = said.map(\.text)
        XCTAssertEqual(texts.filter { $0 == "Lap 2." }.count, 1, texts.joined(separator: " | "))
        XCTAssertEqual(texts.filter { $0 == "Lap 3." }.count, 1)
        XCTAssertFalse(texts.contains("End of route."))
        XCTAssertFalse(texts.contains("Off route."))
        // The turn at the lap junction is called on every pass.
        let joinCalls = said.filter { $0.text == "Turn right now." && abs($0.at - guide.loopEnd) < 40 }
        XCTAssertEqual(joinCalls.count, 1)
        // Laps 2 and 3 repeat the same turns as each other.
        let lap = guide.lapLength
        let lap2 = said.filter { $0.at > guide.loopEnd + 30 && $0.at < guide.loopEnd + lap - 30 && $0.text.hasSuffix(" now.") }
        let lap3 = said.filter { $0.at > guide.loopEnd + lap + 30 && $0.at < guide.loopEnd + 2 * lap - 30 && $0.text.hasSuffix(" now.") }
        XCTAssertEqual(lap2.map(\.text), lap3.map(\.text))
    }

    func testOffRouteAndBack() throws {
        let guide = RouteGuide(route: try load("point-to-point-16.05km"), loop: false)
        // Drift 80 m off the line between 3.0 and 3.4 km.
        let said = simulate(guide) { d in (3000...3400).contains(d) ? 80 : 0 }
        let off = said.firstIndex { $0.text == "Off route." }
        let back = said.firstIndex { $0.text == "Back on route." }
        XCTAssertNotNil(off, said.map(\.text).joined(separator: " | "))
        XCTAssertNotNil(back)
        if let off, let back { XCTAssertLessThan(off, back) }
        XCTAssertEqual(said.filter { $0.text == "Off route." }.count, 1)
        XCTAssertEqual(said.last?.text, "End of route.")
    }

    func testChainedTurnsAreCombined() throws {
        // The 16 km route has a right then a left about 60 m apart near 5.2 km.
        let guide = RouteGuide(route: try load("point-to-point-16.05km"), loop: false)
        let said = simulate(guide)
        XCTAssertTrue(said.contains { $0.text.contains(", then ") }, said.map(\.text).joined(separator: " | "))
    }
}
