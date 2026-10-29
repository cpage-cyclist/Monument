import Foundation

public struct GeoPoint: Hashable, Codable {
    public var lat: Double
    public var lon: Double

    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

/// A point in metres on a flat local grid around the route.
struct Vec: Hashable {
    var x: Double
    var y: Double

    static func - (a: Vec, b: Vec) -> Vec { Vec(x: a.x - b.x, y: a.y - b.y) }
    var length: Double { (x * x + y * y).squareRoot() }
}

/// Flat projection that's accurate to well under a metre over a city-sized area.
struct LocalProjection: Hashable {
    let lat0: Double
    let lon0: Double
    private let mx: Double
    private let my: Double

    init(origin: GeoPoint) {
        lat0 = origin.lat
        lon0 = origin.lon
        let r = 6_371_000.0 * Double.pi / 180
        my = r
        mx = r * cos(origin.lat * Double.pi / 180)
    }

    func xy(_ p: GeoPoint) -> Vec { Vec(x: (p.lon - lon0) * mx, y: (p.lat - lat0) * my) }
    func geo(_ v: Vec) -> GeoPoint { GeoPoint(lat: lat0 + v.y / my, lon: lon0 + v.x / mx) }
}

public enum TurnDirection: Hashable {
    case bearLeft, left, sharpLeft, bearRight, right, sharpRight, turnAround
    /// The line jinks through a junction or crossing but carries on straight.
    case straight

    public var isLeft: Bool { [.bearLeft, .left, .sharpLeft].contains(self) }

    /// Imperative wording, e.g. "turn left", "bear right".
    public var phrase: String {
        switch self {
        case .bearLeft: return "bear left"
        case .left: return "turn left"
        case .sharpLeft: return "sharp left"
        case .bearRight: return "bear right"
        case .right: return "turn right"
        case .sharpRight: return "sharp right"
        case .turnAround: return "turn around"
        case .straight: return "straight on"
        }
    }

    /// Short wording for chained cues, e.g. "then left".
    public var short: String {
        switch self {
        case .left: return "left"
        case .right: return "right"
        default: return phrase
        }
    }
}

public struct RouteTurn: Hashable {
    /// Distance along the route, in metres.
    public let at: Double
    public let direction: TurnDirection
    /// The line weaves through a junction (several bends close together).
    public let tricky: Bool
    public let point: GeoPoint
    /// Net change of heading in degrees (negative = left).
    public let angle: Double
}

/// A route imported from a GPX/TCX file, with turns worked out from the line.
public struct Route {
    public let name: String
    public let points: [GeoPoint]
    /// Start and finish within 50 m of each other.
    public let isLoop: Bool
    /// Length in metres (including closing the loop).
    public let length: Double
    public let turns: [RouteTurn]
    /// Waypoints from the file (GPX `<wpt>`), which can mark efforts: see `RouteEfforts`.
    public var waypoints: [RouteWaypoint] = []

    let projection: LocalProjection
    /// The line resampled every `RouteGeometry.step` metres.
    let samples: [Vec]
    /// Distance along the route of each sample.
    let cumulative: [Double]

    public init(name: String, points rawPoints: [GeoPoint]) {
        // Drop exact duplicates, which Strava exports sometimes contain.
        var points: [GeoPoint] = []
        for p in rawPoints where points.last != p { points.append(p) }

        let proj = LocalProjection(origin: points.first ?? GeoPoint(lat: 0, lon: 0))
        var xy = points.map { proj.xy($0) }
        let loop = xy.count > 2 && (xy[0] - xy[xy.count - 1]).length <= 50
        if loop, let first = xy.first, (first - xy[xy.count - 1]).length > 0.5 {
            xy.append(first)
        }
        let (s, c) = RouteGeometry.resample(xy)
        let found = TurnDetector.turns(samples: s, cumulative: c, loop: loop)

        self.name = name
        self.points = points
        projection = proj
        isLoop = loop
        samples = s
        cumulative = c
        length = c.last ?? 0
        turns = found.map { t in
            RouteTurn(at: t.at, direction: t.direction, tricky: t.tricky,
                      point: proj.geo(t.position), angle: t.angle)
        }
    }

    /// Where on the route a distance falls (wraps for loops).
    public func point(at distance: Double) -> GeoPoint {
        guard samples.count > 1, length > 0 else { return points.first ?? GeoPoint(lat: 0, lon: 0) }
        var d = distance
        if isLoop { d = d.truncatingRemainder(dividingBy: length); if d < 0 { d += length } }
        d = min(max(0, d), length)
        let i = min(samples.count - 2, max(0, Int(d / RouteGeometry.step)))
        var j = i
        while j < samples.count - 2 && cumulative[j + 1] < d { j += 1 }
        let seg = cumulative[j + 1] - cumulative[j]
        let t = seg > 0 ? (d - cumulative[j]) / seg : 0
        let a = samples[j], b = samples[j + 1]
        return projection.geo(Vec(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
    }

    /// Heading of the first 40 m, as a compass word.
    public var startHeading: String {
        guard samples.count > 8 else { return "" }
        let b = RouteGeometry.bearing(samples[0], samples[8])
        let names = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
        return names[Int((b / 45).rounded()) % 8]
    }
}

enum RouteGeometry {
    static let step = 5.0

    /// Bearing in degrees clockwise from north.
    static func bearing(_ a: Vec, _ b: Vec) -> Double {
        let d = atan2(b.x - a.x, b.y - a.y) * 180 / Double.pi
        return d < 0 ? d + 360 : d
    }

    /// Signed change of heading from b1 to b2, in -180...180 (negative = left).
    static func delta(_ b1: Double, _ b2: Double) -> Double {
        var d = (b2 - b1 + 540).truncatingRemainder(dividingBy: 360) - 180
        if d < -180 { d += 360 }
        return d
    }

    /// Points every `step` metres along the line, plus the exact end point.
    static func resample(_ pts: [Vec]) -> ([Vec], [Double]) {
        guard let first = pts.first else { return ([], []) }
        var out = [first]
        var cum = [0.0]
        var travelled = 0.0
        var nextMark = step
        for k in 1..<max(1, pts.count) {
            let a = pts[k - 1], b = pts[k]
            let d = (b - a).length
            if d == 0 { continue }
            while nextMark <= travelled + d {
                let f = (nextMark - travelled) / d
                out.append(Vec(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
                cum.append(nextMark)
                nextMark += step
            }
            travelled += d
        }
        if let last = pts.last, travelled - (cum.last ?? 0) > 0.01 {
            out.append(last)
            cum.append(travelled)
        }
        return (out, cum)
    }

    /// Nearest point on segment a→b to p: (distance from p, fraction along the segment).
    static func project(_ p: Vec, _ a: Vec, _ b: Vec) -> (distance: Double, t: Double) {
        let ab = b - a
        let len2 = ab.x * ab.x + ab.y * ab.y
        var t = len2 > 0 ? ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / len2 : 0
        t = min(1, max(0, t))
        let q = Vec(x: a.x + ab.x * t, y: a.y + ab.y * t)
        return ((p - q).length, t)
    }
}

/// Finds turns from the shape of the line. Tuned on Strava routes, whose points
/// sit on real junctions but can be 20–100 m apart on straights.
enum TurnDetector {
    struct Found {
        let at: Double
        let angle: Double
        let position: Vec
        let direction: TurnDirection
        let tricky: Bool
    }

    struct Raw {
        let index: Int
        let angle: Double
    }

    static let window = 3          // samples (15 m) either side for the local bend
    static let candidate = 35.0    // degrees of local bend to count as a possible turn
    static let side = 5            // samples (25 m) used to measure the net turn
    static let mergeSpan = 40.0    // bends within this many metres become one turn
    static let straightSwing = 140.0 // total bending in a cluster that nets straight → "straight on"

    static func turns(samples: [Vec], cumulative: [Double], loop: Bool) -> [Found] {
        guard samples.count > 2 * (window + side) else { return [] }
        let step = RouteGeometry.step

        // For loops, wrap the line round so turns at the start/finish are found.
        let pad = loop ? 20 : 0
        var line = samples
        if loop {
            let body = Array(samples.dropLast())
            line = Array(body.suffix(pad)) + samples + Array(samples.dropFirst().prefix(pad))
        }
        let n = line.count

        // Local bend at each sample.
        var ang = [Double](repeating: 0, count: n)
        for i in window..<(n - window) {
            ang[i] = RouteGeometry.delta(RouteGeometry.bearing(line[i - window], line[i]),
                                         RouteGeometry.bearing(line[i], line[i + window]))
        }

        // Runs of consecutive samples that bend sharply → one raw turn each.
        var raws: [Raw] = []
        var run: [Int] = []
        func closeRun() {
            guard let s = run.first, let e = run.last else { return }
            let a = max(0, s - side), b = min(n - 1, e + side)
            if b - a >= 2 {
                let before = RouteGeometry.bearing(line[a], line[min(s, a + side)])
                let after = RouteGeometry.bearing(line[max(e, b - side)], line[b])
                let peak = run.max { abs(ang[$0]) < abs(ang[$1]) } ?? s
                raws.append(Raw(index: peak, angle: RouteGeometry.delta(before, after)))
            }
            run = []
        }
        for i in 0..<n {
            if abs(ang[i]) >= candidate { run.append(i) } else { closeRun() }
        }
        closeRun()

        // Merge bends that are close together; the cue is the net direction.
        var clusters: [[Raw]] = []
        for r in raws {
            if let last = clusters.last?.last, Double(r.index - last.index) * step <= mergeSpan {
                clusters[clusters.count - 1].append(r)
            } else {
                clusters.append([r])
            }
        }

        var found: [Found] = []
        for c in clusters {
            guard let first = c.first, let last = c.last else { continue }
            var net = first.angle
            var tricky = false
            if c.count > 1 {
                let a = max(0, first.index - side), b = min(n - 1, last.index + side)
                guard a + side < n, b - side >= 0 else { continue }
                net = RouteGeometry.delta(RouteGeometry.bearing(line[a], line[a + side]),
                                          RouteGeometry.bearing(line[b - side], line[b]))
                let swing = c.reduce(0) { $0 + abs($1.angle) }
                tricky = c.count >= 3 || (swing >= 150 && abs(net) >= 40)
            }
            var direction = classify(net)
            if direction == nil && c.count >= 2 && c.reduce(0, { $0 + abs($1.angle) }) >= straightSwing {
                // Weaves across a road or staggered junction but carries on: say so.
                direction = .straight
                tricky = false
            }
            guard let direction else { continue }

            // Map back to a distance along the real route.
            let original = first.index - pad
            let at: Double
            if loop {
                guard original >= 0 && original < samples.count - 1 else { continue }
                at = cumulative[original]
            } else {
                at = cumulative[first.index]
                guard at > 10 && at < (cumulative.last ?? 0) - 10 else { continue }
            }
            found.append(Found(at: at, angle: net, position: line[first.index], direction: direction, tricky: tricky))
        }
        return found.sorted { $0.at < $1.at }
    }

    static func classify(_ net: Double) -> TurnDirection? {
        let a = abs(net)
        let left = net < 0
        if a < 40 { return nil }
        if a < 65 { return left ? .bearLeft : .bearRight }
        if a < 140 { return left ? .left : .right }
        if a < 165 { return left ? .sharpLeft : .sharpRight }
        return .turnAround
    }
}
