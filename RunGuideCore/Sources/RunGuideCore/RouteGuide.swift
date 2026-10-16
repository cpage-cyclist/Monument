import Foundation

/// A turn as it appears in the lap being run, with its position on the
/// unrolled course (distance from the start of the run along the route).
public struct UpcomingTurn: Hashable {
    public let turn: RouteTurn
    /// Metres from where you are now.
    public let distance: Double
}

/// Follows the runner along a route from GPS fixes and decides what to say:
/// turn heads-ups and "now" calls, off-route warnings, laps and the end of the route.
///
/// Position is tracked *forward* along the route (a window ahead of the last
/// known point), so routes that cross or double back on themselves don't
/// confuse it.
public final class RouteGuide {
    public let route: Route
    public let looping: Bool

    /// Distance covered along the unrolled course (keeps growing over laps).
    public private(set) var progress: Double?
    public private(set) var lap = 1
    public private(set) var offRoute = false
    public private(set) var finished = false

    // Settings
    public var headsUp = 100.0          // metres before a turn for the heads-up
    public var nowDistance = 15.0       // metres before a turn for "… now"
    public var chainDistance = 70.0     // turns this close follow on with "then …"

    // Loop geometry: laps run between loopStart and loopEnd. A shared stub at
    // the start/finish (start up a side road, come back the same way) is only
    // run on the first lap.
    let loopStart: Double
    let loopEnd: Double
    let joinTurn: RouteTurn?
    let firstLapTurns: [RouteTurn]
    let laterLapTurns: [RouteTurn]

    private var fired = Set<String>()
    private var offSince: Date?
    private var lastMatchDistance = 0.0

    public init(route: Route, loop: Bool) {
        self.route = route
        looping = loop && route.isLoop

        let (start, end, join) = RouteGuide.loopGeometry(route)
        loopStart = start
        loopEnd = end
        joinTurn = join
        if looping {
            firstLapTurns = route.turns.filter { $0.at < end - 15 }
            laterLapTurns = route.turns.filter { $0.at > start + 15 && $0.at < end - 15 }
        } else {
            firstLapTurns = route.turns
            laterLapTurns = []
        }
    }

    public var lapLength: Double { looping ? loopEnd - loopStart : route.length }

    /// The next turn ahead, for the screen.
    public var nextTurn: UpcomingTurn? {
        guard let u = progress, !finished else { return nil }
        return schedule(from: u, horizon: 5000).first { $0.at > u - 2 }
            .map { UpcomingTurn(turn: $0.turn, distance: max(0, $0.at - u)) }
    }

    /// Distance into the current lap (or the route), for the screen.
    public var distanceIntoLap: Double? {
        guard let u = progress else { return nil }
        if !looping || u <= loopEnd { return u }
        return (u - loopEnd).truncatingRemainder(dividingBy: lapLength)
    }

    // MARK: - Feeding it

    /// Feed a GPS fix. Returns anything that should be said, most urgent first.
    public func update(lat: Double, lon: Double, accuracy: Double, time: Date) -> [String] {
        guard !finished, route.samples.count > 1 else { return [] }
        let p = route.projection.xy(GeoPoint(lat: lat, lon: lon))
        let acc = min(max(accuracy, 5), 30)
        var speech: [String] = []

        guard let u = progress else {
            // Not on the route yet: pick it up once within 60 m of any part of it.
            if let m = nearest(p, from: 0, to: route.length), m.distance <= 60 {
                progress = m.along
                lastMatchDistance = m.distance
            }
            return []
        }

        // Look a little behind and well ahead of where we were.
        let behind = offRoute ? 100.0 : 50.0
        let ahead = offRoute ? 1500.0 : 300.0
        var match = nearestAhead(p, from: u - behind, to: u + ahead)
        let weak = match.map { $0.distance > 30 } ?? true
        if offRoute, weak, let any = nearest(p, from: 0, to: route.length) {
            // Rejoined somewhere else entirely (shortcut etc.).
            match = (along: unrolled(routeDistance: any.along, near: u), distance: any.distance)
        }

        let onThreshold = 25.0 + acc * 0.5
        let offThreshold = 40.0 + acc * 0.5

        if let m = match, m.distance <= onThreshold {
            if m.along > u - 30 { progress = max(m.along, u - 30) }
            lastMatchDistance = m.distance
            offSince = nil
            if offRoute {
                offRoute = false
                speech.append("Back on route.")
            }
        } else {
            let d = match?.distance ?? .infinity
            lastMatchDistance = d
            if d > offThreshold {
                if offSince == nil { offSince = time }
                if !offRoute, let since = offSince, time.timeIntervalSince(since) >= 6 {
                    offRoute = true
                    speech.append("Off route.")
                }
            }
        }

        guard let now = progress, !offRoute else { return speech }

        // Laps.
        if looping {
            let newLap = now < loopEnd ? 1 : 2 + Int((now - loopEnd) / lapLength)
            if newLap > lap {
                lap = newLap
                speech.append("Lap \(lap).")
            }
        } else if now >= route.length - 25 {
            finished = true
            speech.append("End of route.")
            return speech
        }

        speech += turnCues(at: now)
        return speech
    }

    // MARK: - Turn cues

    struct Scheduled {
        let at: Double
        let turn: RouteTurn
        let key: String
    }

    /// Turns on the unrolled course from `u` up to `horizon` metres ahead.
    func schedule(from u: Double, horizon: Double) -> [Scheduled] {
        var out: [Scheduled] = []
        let limit = u + horizon
        // Lap 1 (or the whole route).
        for (i, t) in firstLapTurns.enumerated() where t.at >= u - 20 && t.at <= limit {
            out.append(Scheduled(at: t.at, turn: t, key: "1-\(i)"))
        }
        guard looping else { return out }
        // The junction at the end of every lap, then later laps.
        var lapN = 1
        var lapStartU = loopEnd    // where lap N+1 starts on the unrolled course
        while lapStartU - 20 <= limit && lapN < 1000 {
            if let j = joinTurn, lapStartU >= u - 20 {
                out.append(Scheduled(at: lapStartU, turn: j, key: "J\(lapN)"))
            }
            for (i, t) in laterLapTurns.enumerated() {
                let at = lapStartU + (t.at - loopStart)
                if at >= u - 20 && at <= limit {
                    out.append(Scheduled(at: at, turn: t, key: "\(lapN + 1)-\(i)"))
                }
            }
            lapN += 1
            lapStartU += lapLength
        }
        return out.sorted { $0.at < $1.at }
    }

    private func turnCues(at u: Double) -> [String] {
        let upcoming = schedule(from: u, horizon: headsUp + 4 * chainDistance)
        var speech: [String] = []

        for (i, s) in upcoming.enumerated() {
            let remaining = s.at - u
            if remaining > headsUp { break }

            // "… now" as you reach it.
            if remaining <= nowDistance {
                if !fired.contains("now-\(s.key)") && remaining > -10 {
                    fired.insert("now-\(s.key)")
                    fired.insert("pre-\(s.key)")
                    speech.append(Self.capitalised(Self.phrase(s.turn)) + " now.")
                }
                continue
            }

            // Heads-up, chaining any turns that follow closely.
            if remaining > 35 && !fired.contains("pre-\(s.key)") {
                var text = "In \(Self.roundedDistance(remaining)), \(Self.phrase(s.turn))"
                var previous = s
                for next in upcoming.dropFirst(i + 1) {
                    guard next.at - previous.at <= chainDistance else { break }
                    text += ", then \(next.turn.direction.short)"
                    fired.insert("pre-\(next.key)")
                    previous = next
                }
                fired.insert("pre-\(s.key)")
                speech.append(text + ".")
            }
        }
        return speech
    }

    static func phrase(_ t: RouteTurn) -> String {
        t.tricky ? "tricky junction, \(t.direction.phrase)" : t.direction.phrase
    }

    static func capitalised(_ s: String) -> String {
        s.prefix(1).uppercased() + s.dropFirst()
    }

    static func roundedDistance(_ metres: Double) -> String {
        let m = max(10, Int((metres / 10).rounded()) * 10)
        return "\(m) metres"
    }

    // MARK: - Matching

    /// Nearest point on the route between two route distances (no wrapping).
    func nearest(_ p: Vec, from a: Double, to b: Double) -> (along: Double, distance: Double)? {
        let s = route.samples, c = route.cumulative
        guard s.count > 1 else { return nil }
        let i0 = max(0, min(s.count - 2, Int(max(0, a) / RouteGeometry.step) - 1))
        let i1 = max(0, min(s.count - 2, Int(max(0, b) / RouteGeometry.step) + 1))
        guard i0 <= i1 else { return nil }
        var best: (along: Double, distance: Double)?
        for i in i0...i1 {
            let r = RouteGeometry.project(p, s[i], s[i + 1])
            if best == nil || r.distance < best!.distance {
                best = (along: c[i] + (c[i + 1] - c[i]) * r.t, distance: r.distance)
            }
        }
        return best
    }

    /// Nearest point within a window of the unrolled course.
    func nearestAhead(_ p: Vec, from a: Double, to b: Double) -> (along: Double, distance: Double)? {
        guard looping else { return nearest(p, from: a, to: b) }
        var best: (along: Double, distance: Double)?
        // Walk the window lap by lap.
        var segStart = a
        while segStart < b {
            let (lapIndex, d) = routePosition(segStart)
            let lapEndD = loopEnd
            let span = min(b - segStart, lapEndD - d)
            if span <= 0 { segStart += 1; continue }
            if let m = nearest(p, from: d, to: d + span), best == nil || m.distance < best!.distance {
                best = (along: unrolled(lap: lapIndex, routeDistance: m.along), distance: m.distance)
            }
            segStart += span + 0.001
        }
        return best
    }

    /// Unrolled distance → (lap number, distance along the route file).
    func routePosition(_ u: Double) -> (Int, Double) {
        if !looping || u < loopEnd { return (1, max(0, u)) }
        let k = Int((u - loopEnd) / lapLength)
        return (k + 2, loopStart + (u - loopEnd) - Double(k) * lapLength)
    }

    func unrolled(lap: Int, routeDistance d: Double) -> Double {
        if !looping || lap <= 1 { return d }
        return loopEnd + Double(lap - 2) * lapLength + (d - loopStart)
    }

    /// Unrolled distance for a route distance, choosing the lap closest to `u`.
    func unrolled(routeDistance d: Double, near u: Double) -> Double {
        guard looping else { return d }
        let (lapNow, _) = routePosition(u)
        let options = [max(1, lapNow - 1), lapNow, lapNow + 1].map { unrolled(lap: $0, routeDistance: d) }
        return options.min { abs($0 - u) < abs($1 - u) } ?? d
    }

    // MARK: - Loop geometry

    /// Finds a shared stub at the start/finish and the turn at the lap junction.
    static func loopGeometry(_ route: Route) -> (Double, Double, RouteTurn?) {
        let s = route.samples, c = route.cumulative
        let n = s.count
        guard route.isLoop, n > 20 else { return (0, route.length, nil) }

        var i = 0
        while i < n / 2 && (s[i] - s[n - 1 - i]).length <= 12 { i += 1 }
        let stub = i > 0 ? c[i - 1] : 0
        let (si, ei) = stub >= 15 ? (i - 1, n - i) : (0, n - 1)
        let side = TurnDetector.side
        let arrival = RouteGeometry.bearing(s[max(0, ei - side)], s[ei])
        let departure = RouteGeometry.bearing(s[si], s[min(n - 1, si + side)])
        let net = RouteGeometry.delta(arrival, departure)
        let join = TurnDetector.classify(net).map {
            RouteTurn(at: c[ei], direction: $0, tricky: false, point: route.projection.geo(s[ei]), angle: net)
        }
        return (c[si], c[ei], join)
    }
}
