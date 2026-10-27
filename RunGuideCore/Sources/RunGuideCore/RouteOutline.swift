import Foundation

/// A route's shape, small enough to keep with the route list and draw as a thumbnail without
/// opening the full GPX or loading map tiles.
public enum RouteOutline {

    /// Decodes a Google encoded polyline (Strava's `map.summary_polyline`) at 1e5 precision.
    /// Returns nil for malformed input.
    public static func decodePolyline(_ encoded: String) -> [GeoPoint]? {
        var points: [GeoPoint] = []
        let bytes = Array(encoded.utf8)
        var index = 0
        var lat = 0
        var lon = 0

        func next() -> Int? {
            var result = 0
            var shift = 0
            while true {
                guard index < bytes.count else { return nil }
                let b = Int(bytes[index]) - 63
                index += 1
                guard b >= 0 else { return nil }
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20 { break }
                guard shift < 64 else { return nil }
            }
            return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
        }

        while index < bytes.count {
            guard let dLat = next(), let dLon = next() else { return nil }
            lat += dLat
            lon += dLon
            points.append(GeoPoint(lat: Double(lat) / 1e5, lon: Double(lon) / 1e5))
        }
        return points
    }

    /// Thins a line to at most `maxPoints` while keeping its shape (Douglas–Peucker, tightening
    /// the tolerance until the line fits). Always keeps the first and last points.
    public static func simplify(_ points: [GeoPoint], maxPoints: Int = 80) -> [GeoPoint] {
        guard points.count > max(maxPoints, 2), let origin = points.first else { return points }
        let projection = LocalProjection(origin: origin)
        let xy = points.map(projection.xy)

        // Start from a tolerance relative to the line's size and loosen it until it fits.
        let xs = xy.map(\.x), ys = xy.map(\.y)
        let span = max((xs.max()! - xs.min()!), (ys.max()! - ys.min()!), 1)
        var tolerance = span / 400
        var kept = douglasPeucker(xy, tolerance: tolerance)
        while kept.count > maxPoints {
            tolerance *= 1.5
            kept = douglasPeucker(xy, tolerance: tolerance)
        }
        return kept.map { points[$0] }
    }

    /// The outline scaled into a unit square (0...1 on both axes, y pointing down as on screen),
    /// keeping the route's true proportions and centred on the shorter axis.
    public static func normalised(_ points: [GeoPoint]) -> [(x: Double, y: Double)] {
        guard let origin = points.first else { return [] }
        let projection = LocalProjection(origin: origin)
        let xy = points.map(projection.xy)
        let minX = xy.map(\.x).min()!, maxX = xy.map(\.x).max()!
        let minY = xy.map(\.y).min()!, maxY = xy.map(\.y).max()!
        let w = maxX - minX, h = maxY - minY
        let side = max(w, h, 1)
        let padX = (side - w) / 2, padY = (side - h) / 2
        return xy.map { v in
            (x: (v.x - minX + padX) / side,
             y: 1 - (v.y - minY + padY) / side)
        }
    }

    /// Indices of the points kept by Douglas–Peucker.
    static func douglasPeucker(_ xy: [Vec], tolerance: Double) -> [Int] {
        guard xy.count > 2 else { return Array(xy.indices) }
        var keep = [Bool](repeating: false, count: xy.count)
        keep[0] = true
        keep[xy.count - 1] = true
        var stack = [(0, xy.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            var worst = -1.0
            var worstIndex = a
            for i in (a + 1)..<b {
                let d = distance(xy[i], fromSegment: xy[a], xy[b])
                if d > worst { worst = d; worstIndex = i }
            }
            if worst > tolerance {
                keep[worstIndex] = true
                stack.append((a, worstIndex))
                stack.append((worstIndex, b))
            }
        }
        return keep.indices.filter { keep[$0] }
    }

    static func distance(_ p: Vec, fromSegment a: Vec, _ b: Vec) -> Double {
        let ab = b - a
        let lengthSquared = ab.x * ab.x + ab.y * ab.y
        guard lengthSquared > 0 else { return (p - a).length }
        let ap = p - a
        let t = min(max((ap.x * ab.x + ap.y * ab.y) / lengthSquared, 0), 1)
        return (p - Vec(x: a.x + ab.x * t, y: a.y + ab.y * t)).length
    }
}
