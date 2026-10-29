import Foundation

// Workout routes: efforts marked on a saved route with waypoints (dropped in Strava, or <wpt> in a
// GPX file), played by place rather than by time. They live with the route in Monument only:
// Intervals' workout text has no way to say "start at this point", so nothing goes to Intervals
// except the finished ride.
//
// Waypoint titles, any case:
//
//     GO                 effort starts here, no target
//     GO 350W            …with a target: watts, % of FTP, a zone, or a pace (GO 4:00/km)
//     GO 340-360W        …or a range
//     GO MAX             all out
//     GO 5m 350W         a timed (or measured: GO 2km, GO 500m) effort from here
//     EASY / END / STOP  the effort ends here
//
// An effort runs until its own length, an EASY, the next GO or the end of the route, whichever
// comes first. Anything else is an ordinary waypoint and is ignored.

/// A waypoint on a saved route.
public struct RouteWaypoint: Codable, Hashable, Sendable {
    public var title: String
    public var note: String?
    public var lat: Double
    public var lon: Double
    /// Metres into the route, when Strava gives it.
    public var distance: Double?

    public init(title: String, note: String? = nil, lat: Double, lon: Double, distance: Double? = nil) {
        self.title = title
        self.note = note
        self.lat = lat
        self.lon = lon
        self.distance = distance
    }
}

/// What a waypoint title asks for.
public enum RouteCommand: Equatable, Sendable {
    case go(length: PlanLength?, target: PlanTarget?, max: Bool)
    case easy

    /// Nil for an ordinary waypoint. A GO only counts when every word after it is understood, so
    /// "Go left at the pub" stays a normal waypoint.
    public init?(title: String) {
        let tokens = title.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,!:;")) }
            .filter { !$0.isEmpty }
        guard let first = tokens.first?.lowercased() else { return nil }
        if ["easy", "end", "stop"].contains(first) {
            guard tokens.count == 1 else { return nil }
            self = .easy
            return
        }
        guard first == "go" else { return nil }
        var rest = Array(tokens.dropFirst())
        var length: PlanLength?
        var target: PlanTarget?
        var max = false
        while !rest.isEmpty {
            let token = rest.removeFirst()
            let lower = token.lowercased()
            if lower == "max" || lower == "all-out" { max = true; continue }
            if length == nil, let l = Self.length(lower) { length = l; continue }
            if target == nil, let read = PlanTarget.read(token: token, next: rest.first) {
                if read.consumesNext { rest.removeFirst() }
                target = read.target
                continue
            }
            return nil
        }
        self = .go(length: length, target: target, max: max)
    }

    /// Lengths as in Intervals text, except that a bare `Xm` of 100 or more is metres: on a
    /// waypoint "GO 500m" means a distance, not 500 minutes.
    static func length(_ token: String) -> PlanLength? {
        if let m = firstMatch(#"^(\d+)m$"#, in: token), let v = Double(m[1]), v >= 100 { return .distance(v) }
        return PlanLength(token: token)
    }
}

/// One effort on a route.
public struct RouteEffort: Hashable, Sendable {
    /// 1-based, in route order.
    public let number: Int
    /// Metres along the route where it starts.
    public let start: Double
    /// Where an EASY or the next GO ends it, if anywhere.
    public let stop: Double?
    /// Its own length, if it has one.
    public let length: PlanLength?
    public let target: PlanTarget?
    public let max: Bool

    public init(number: Int, start: Double, stop: Double?, length: PlanLength?, target: PlanTarget?, max: Bool) {
        self.number = number
        self.start = start
        self.stop = stop
        self.length = length
        self.target = target
        self.max = max
    }

    public var label: String { "Effort \(number)" }

    /// Watts to aim for, when the target is power and FTP is known.
    public func watts(ftp: Double?) -> ClosedRange<Double>? {
        guard !max, let target else { return nil }
        if target.metric == .power, target.mode == .absolute { return target.watts(ftp: 0) }
        return ftp.flatMap { target.watts(ftp: $0) }
    }

    /// "350w", "Z4", "4:00/km Pace", "max", for the screen.
    public var targetText: String? { max ? "Max" : target?.text }

    /// "5 minutes at 350 watts", "max", "to the marker at zone 4"; empty when there's nothing to say.
    public var spoken: String {
        var parts: [String] = []
        switch length {
        case .time(let s): parts.append(Speech.duration(s))
        case .distance(let d): parts.append(Speech.distance(d))
        case nil: break
        }
        if max {
            parts.append(parts.isEmpty ? "max" : "all out")
        } else if let target {
            parts.append((parts.isEmpty ? "" : "at ") + Speech.target(target.text))
        }
        return parts.joined(separator: " ")
    }
}

public enum RouteEfforts {
    /// How far from the line a waypoint may sit and still be snapped to it, metres.
    static let snapDistance = 100.0
    /// Efforts shorter than this along the route are dropped as mis-taps.
    static let minimumLength = 20.0

    /// The efforts a route's waypoints describe, in route order.
    public static func plan(_ waypoints: [RouteWaypoint], route: Route) -> [RouteEffort] {
        // Strava gives each waypoint's distance into the route; files don't, so those are snapped
        // in the order given, each looking forward from the last (out-and-back routes pass the
        // same spot twice).
        let allMeasured = waypoints.allSatisfy { $0.distance != nil }
        let ordered = allMeasured ? waypoints.sorted { $0.distance! < $1.distance! } : waypoints
        var marks: [(at: Double, command: RouteCommand)] = []
        var cursor = 0.0
        for w in ordered {
            guard let command = RouteCommand(title: w.title) else { continue }
            let at = w.distance.map { min(Swift.max($0, 0), route.length) }
                ?? along(GeoPoint(lat: w.lat, lon: w.lon), route: route, after: cursor)
            guard let at else { continue }
            cursor = at
            marks.append((at, command))
        }
        marks.sort { $0.at < $1.at }

        var out: [RouteEffort] = []
        var open: (start: Double, length: PlanLength?, target: PlanTarget?, max: Bool)?
        func close(at stop: Double?) {
            guard let o = open else { return }
            open = nil
            if let stop, stop - o.start < minimumLength { return }
            out.append(RouteEffort(number: out.count + 1, start: o.start, stop: stop,
                                   length: o.length, target: o.target, max: o.max))
        }
        for mark in marks {
            switch mark.command {
            case .go(let length, let target, let max):
                close(at: mark.at)
                open = (mark.at, length, target, max)
            case .easy:
                close(at: mark.at)
            }
        }
        if let o = open, route.length - o.start >= minimumLength { close(at: nil) } else { open = nil }
        return out
    }

    /// Where a point sits along the route, looking from `after` onwards: the first pass within a
    /// few metres of the closest one, so an out-and-back picks the leg you reach first.
    static func along(_ point: GeoPoint, route: Route, after: Double) -> Double? {
        let s = route.samples, c = route.cumulative
        guard s.count > 1 else { return nil }
        let p = route.projection.xy(point)
        var hits: [(along: Double, distance: Double)] = []
        for i in 0..<(s.count - 1) where c[i + 1] >= after {
            let r = RouteGeometry.project(p, s[i], s[i + 1])
            hits.append((c[i] + (c[i + 1] - c[i]) * r.t, r.distance))
        }
        guard let closest = hits.map(\.distance).min(), closest <= snapDistance,
              var j = hits.firstIndex(where: { $0.distance <= closest + 15 }) else { return nil }
        // Then down to the nearest point of that pass.
        while j + 1 < hits.count, hits[j + 1].distance <= hits[j].distance { j += 1 }
        return Swift.max(hits[j].along, after)
    }
}

extension RecordSport {
    /// Spoken heads-ups before a route effort, metres: a bike needs more warning.
    public var effortHeadsUps: [Double] { self == .ride ? [500, 200] : [200] }
}

// MARK: - Playing a route's efforts

public enum EffortEvent: Equatable {
    case speak(String, urgent: Bool)
    case started(RouteEffort)
    case ended(RouteEffort)
    case skipped(RouteEffort)
}

/// Follows the efforts along a route as the route guide tracks you: heads-ups, a countdown timed
/// from your speed, then the effort until its length, an EASY or the next GO. An effort you reach
/// off route, or jump past (rejoining further on), is dropped rather than fired late. On a looped
/// route the efforts come round every lap.
public final class RouteEffortPlayer {
    public let efforts: [RouteEffort]
    public let sport: RecordSport
    public let guide: RouteGuide

    /// The effort under way, with where it started (unrolled metres) and the timer time then.
    public private(set) var active: (effort: RouteEffort, startU: Double, startTime: Double)?
    private var done = Set<String>()
    private var spoken = Set<String>()
    private var lastU: Double?

    public init(efforts: [RouteEffort], guide: RouteGuide, sport: RecordSport) {
        self.efforts = efforts
        self.guide = guide
        self.sport = sport
    }

    /// The next effort ahead and how far away it is, for the screen.
    public var upcoming: (effort: RouteEffort, distance: Double)? {
        guard active == nil, let u = guide.progress, let next = next(from: lastU ?? u) else { return nil }
        return (next.effort, Swift.max(0, next.u - u))
    }

    /// Time and metres into the active effort.
    public func activeProgress(time: Double) -> (seconds: Double, metres: Double)? {
        guard let a = active, let u = guide.progress else { return nil }
        return (time - a.startTime, Swift.max(0, u - a.startU))
    }

    /// Call on every update. `time` is the session's timer time (pauses excluded), `speed` m/s.
    public func update(time: Double, speed: Double?) -> [EffortEvent] {
        guard let u = guide.progress else { return [] }
        defer { lastU = u }
        var out: [EffortEvent] = []

        if let a = active {
            var over = guide.finished
            // A metre's grace so GPS rounding doesn't carry an effort a fix past its EASY.
            if let stop = a.effort.stop, u >= a.startU + (stop - a.effort.start) - 1 { over = true }
            switch a.effort.length {
            case .time(let s) where time - a.startTime >= s: over = true
            case .distance(let d) where u - a.startU >= d: over = true
            default: break
            }
            guard over else { return out }
            active = nil
            out.append(.ended(a.effort))
            out.append(.speak("\(a.effort.label) done. Easy.", urgent: false))
        }
        guard !guide.finished, let next = next(from: lastU ?? u) else { return out }

        let ahead = next.u - u
        if ahead <= 0 {
            done.insert(next.key)
            if guide.offRoute || ahead < -40 {
                out.append(.skipped(next.effort))
                return out
            }
            // Measured from where the effort is marked, not where the fix happened to land.
            active = (next.effort, next.u, time)
            out.append(.started(next.effort))
            if !spoken.contains("go-\(next.key)") {
                let what = next.effort.spoken
                out.append(.speak(what.isEmpty ? "Go." : "Go. \(Speech.capitalisedFirst(what)).", urgent: true))
            }
            return out
        }
        guard !guide.offRoute else { return out }

        // Countdown: three seconds out at your current speed.
        if let v = speed, v >= 2, ahead / v <= 3.2, !spoken.contains("go-\(next.key)") {
            spoken.insert("go-\(next.key)")
            for mark in sport.effortHeadsUps { spoken.insert("\(Int(mark))-\(next.key)") }
            out.append(.speak("3, 2, 1, go.", urgent: true))
            return out
        }
        // Heads-ups: the furthest crossed, said once, with what the effort is on the first.
        let marks = sport.effortHeadsUps.sorted(by: >)
        if let mark = marks.filter({ ahead <= $0 && !spoken.contains("\(Int($0))-\(next.key)") }).min() {
            // The first heads-up you hear says what the effort is, even if you joined late.
            let first = !marks.contains { spoken.contains("\(Int($0))-\(next.key)") }
            for m in marks where m >= mark { spoken.insert("\(Int(m))-\(next.key)") }
            let what = next.effort.spoken
            // Joining late, say how far it really is (to the nearest 50 m), not the mark.
            let metres = first && ahead < mark - 25 ? Swift.max(50, Int((ahead / 50).rounded()) * 50) : Int(mark)
            let text = first
                ? "\(next.effort.label) in \(metres) metres" + (what.isEmpty ? "." : ", \(what).")
                : "\(metres) metres."
            out.append(.speak(text, urgent: true))
        }
        return out
    }

    /// The first effort not yet done at or ahead of unrolled metre `u`: (effort, unrolled start, key).
    private func next(from u: Double) -> (effort: RouteEffort, u: Double, key: String)? {
        let (lap, _) = guide.routePosition(u)
        for l in lap...(guide.looping ? lap + 1 : lap) {
            for e in efforts {
                // Later laps only run the loop, not a shared stub at the start.
                if l > 1 && (e.start < guide.loopStart || e.start > guide.loopEnd) { continue }
                let key = "\(l)-\(e.number)"
                let at = guide.unrolled(lap: l, routeDistance: e.start)
                if done.contains(key) || at < u - 0.5 - 60 { continue }
                return (e, at, key)
            }
        }
        return nil
    }
}

extension Speech {
    static func capitalisedFirst(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}
