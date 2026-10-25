import Foundation

// Turns activity streams into what the stacked charts draw: a shared timeline with pauses
// collapsed, the same smoothing choices as the Intervals web view, unit conversions per
// panel, and downsampling to roughly screen resolution so scrolling stays fast.

/// Plotting position for each stream sample. Pauses (gaps in the time stream longer than
/// `maxGap`) are collapsed to a single second, so a café stop doesn't leave a hole.
public struct Timeline: Sendable {
    public let time: [Double]
    /// Seconds of recorded time at each sample; what the charts use as x.
    public let x: [Double]

    public static let maxGap: Double = 10

    public init(time: [Double]) {
        self.time = time
        var x: [Double] = []
        x.reserveCapacity(time.count)
        var position = 0.0
        for i in time.indices {
            if i > 0 {
                let dt = time[i] - time[i - 1]
                position += (dt > 0 && dt <= Self.maxGap) ? dt : (dt > 0 ? 1 : 0)
            }
            x.append(position)
        }
        self.x = x
    }

    public var duration: Double { x.last ?? 0 }
    public var count: Int { x.count }

    /// Sample index closest to a chart position.
    public func index(atX value: Double) -> Int? { Self.nearest(value, in: x) }

    /// Sample index closest to a time from the start of the activity (as laps report it).
    public func index(atTime value: Double) -> Int? { Self.nearest(value, in: time) }

    /// Chart position of a time from the start of the activity.
    public func x(atTime value: Double) -> Double? { index(atTime: value).map { x[$0] } }

    static func nearest(_ value: Double, in sorted: [Double]) -> Int? {
        guard !sorted.isEmpty else { return nil }
        var lo = 0, hi = sorted.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(sorted[lo - 1] - value) <= abs(sorted[lo] - value) { return lo - 1 }
        return lo
    }
}

/// Rolling-average options, matching the Intervals web view's common choices.
public enum Smoothing: Int, CaseIterable, Identifiable, Sendable {
    case off = 0, s3 = 3, s10 = 10, s30 = 30, m1 = 60

    public var id: Int { rawValue }
    public var label: String {
        switch self {
        case .off: return "Off"
        case .s3: return "3s"
        case .s10: return "10s"
        case .s30: return "30s"
        case .m1: return "1m"
        }
    }
}

public struct ChartPoint: Sendable, Hashable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public enum ChartSeries {
    /// Trailing rolling average over `window` seconds of the timeline, ignoring missing
    /// samples. A sample that was missing stays missing.
    public static func smoothed(_ values: [Double?], x: [Double], window: Double) -> [Double?] {
        guard window > 1, values.count == x.count, !values.isEmpty else { return values }
        var result = [Double?](repeating: nil, count: values.count)
        var start = 0
        var sum = 0.0
        var n = 0
        for i in values.indices {
            if let v = values[i] { sum += v; n += 1 }
            while x[i] - x[start] >= window {
                if let v = values[start] { sum -= v; n -= 1 }
                start += 1
            }
            if values[i] != nil, n > 0 { result[i] = sum / Double(n) }
        }
        return result
    }

    /// Reduces a series to about `maxPoints` points, keeping each bucket's lowest and
    /// highest values (in time order) so short spikes and dips still show.
    public static func downsample(x: [Double], y: [Double?], maxPoints: Int) -> [ChartPoint] {
        let n = min(x.count, y.count)
        guard n > 0 else { return [] }
        if n <= maxPoints {
            return (0..<n).compactMap { i in y[i].map { ChartPoint(x: x[i], y: $0) } }
        }
        let buckets = max(maxPoints / 2, 1)
        let size = Double(n) / Double(buckets)
        var out: [ChartPoint] = []
        out.reserveCapacity(buckets * 2)
        for b in 0..<buckets {
            let lo = Int(Double(b) * size)
            let hi = min(Int(Double(b + 1) * size), n)
            var minI = -1, maxI = -1
            for i in lo..<hi {
                guard let v = y[i] else { continue }
                if minI < 0 || v < y[minI]! { minI = i }
                if maxI < 0 || v > y[maxI]! { maxI = i }
            }
            guard minI >= 0 else { continue }
            for i in Set([minI, maxI]).sorted() {
                out.append(ChartPoint(x: x[i], y: y[i]!))
            }
        }
        return out
    }
}

/// One panel in the stacked chart view.
public enum ChartKind: String, CaseIterable, Identifiable, Sendable {
    case power, wbal, heartRate, cadence, speed, pace, altitude

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .power: return "Power"
        case .wbal: return "W'bal"
        case .heartRate: return "Heart rate"
        case .cadence: return "Cadence"
        case .speed: return "Speed"
        case .pace: return "Pace"
        case .altitude: return "Altitude"
        }
    }

    public var unit: String {
        switch self {
        case .power: return "W"
        case .wbal: return "kJ"
        case .heartRate: return "bpm"
        case .cadence: return "rpm"
        case .speed: return "km/h"
        case .pace: return "/km"
        case .altitude: return "m"
        }
    }

    public var stream: StreamType {
        switch self {
        case .power: return .watts
        case .wbal: return .wbal
        case .heartRate: return .heartrate
        case .cadence: return .cadence
        case .speed, .pace: return .velocity
        case .altitude: return .altitude
        }
    }

    /// Pace charts read best with faster (smaller numbers) at the top.
    public var reversed: Bool { self == .pace }

    /// W'bal and altitude are already smooth; smoothing them would only shift them.
    public var smoothable: Bool { self != .wbal && self != .altitude }

    /// Panels to show, top to bottom, for an activity. Runs get pace; everything else speed.
    public static func panels(for streams: ActivityStreams, isRun: Bool) -> [ChartKind] {
        var kinds: [ChartKind] = []
        if streams.has(.watts) { kinds.append(.power) }
        if streams.has(.watts), streams.has(.wbal) { kinds.append(.wbal) }
        if streams.has(.heartrate) { kinds.append(.heartRate) }
        if streams.has(.cadence) { kinds.append(.cadence) }
        if streams.has(.velocity) { kinds.append(isRun ? .pace : .speed) }
        if streams.has(.altitude) { kinds.append(.altitude) }
        return kinds
    }

    /// The stream converted to this panel's unit.
    public func values(from streams: ActivityStreams) -> [Double?] {
        guard let raw = streams[stream] else { return [] }
        switch self {
        case .wbal:
            return raw.map { $0.map { $0 / 1000 } }
        case .speed:
            return raw.map { $0.map { $0 * 3.6 } }
        case .pace:
            // Below ~0.8 m/s (20:50/km) is standing or walking; leave it out of the chart.
            return raw.map { v in v.flatMap { $0 > 0.8 ? 1000 / $0 : nil } }
        case .cadence:
            // Some devices record zero cadence while coasting; that's real and kept.
            return raw
        default:
            return raw
        }
    }

    /// Panels whose scale starts at zero.
    public var zeroBased: Bool { [.power, .wbal, .cadence, .speed].contains(self) }

    /// The y range the panel draws: snapped to the data with 10% headroom (and 10% below the
    /// lowest value on panels that don't start at zero), not rounded up to a round number.
    public func yDomain(for points: [ChartPoint]) -> ClosedRange<Double> {
        guard let lo = points.map(\.y).min(), let hi = points.map(\.y).max() else { return 0...1 }
        if zeroBased {
            let top = hi > 0 ? hi * 1.1 : 1
            return 0...top
        }
        let span = max(hi - lo, minSpan)
        var bottom = lo - span * 0.1
        if self == .heartRate || self == .pace { bottom = max(bottom, 0) }
        return bottom...(hi + span * 0.1)
    }

    /// Stops a flat line filling the whole panel height.
    private var minSpan: Double {
        switch self {
        case .heartRate: return 10
        case .pace: return 30
        case .altitude: return 10
        default: return 1
        }
    }

    /// Short label for the y axis.
    /// Where a value sits on a shared 0–1 scale for overlaid charts (faster pace higher).
    public func normalized(_ v: Double, in domain: ClosedRange<Double>) -> Double {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return 0.5 }
        let f = (v - domain.lowerBound) / span
        return reversed ? 1 - f : f
    }

    /// The value at a point on the shared 0–1 scale.
    public func value(atNormalized f: Double, in domain: ClosedRange<Double>) -> Double {
        let g = reversed ? 1 - f : f
        return domain.lowerBound + g * (domain.upperBound - domain.lowerBound)
    }

    public func axisLabel(_ v: Double) -> String {
        switch self {
        case .pace: return Format.pace(v)
        default: return abs(v) < 10 && v != v.rounded() ? String(format: "%.1f", v) : String(Int(v.rounded()))
        }
    }

    /// The value as shown in the panel's readout.
    public func format(_ value: Double?) -> String {
        guard let v = value, v.isFinite else { return "–" }
        switch self {
        case .wbal: return String(format: "%.1f", v)
        case .speed: return String(format: "%.1f", v)
        case .pace: return Format.pace(v)
        default: return String(Int(v.rounded()))
        }
    }
}

/// Everything one activity's chart stack needs, built once per smoothing choice.
public struct ChartStack: Sendable {
    public struct Panel: Sendable, Identifiable {
        public let kind: ChartKind
        /// Full-resolution values (smoothed), for the scrub readout.
        public let values: [Double?]
        /// Downsampled points for drawing.
        public let points: [ChartPoint]
        public var id: String { kind.id }

        public func value(at index: Int?) -> Double? {
            guard let index, values.indices.contains(index) else { return nil }
            return values[index]
        }
    }

    public let timeline: Timeline
    public let panels: [Panel]

    public init(streams: ActivityStreams, isRun: Bool, smoothing: Smoothing, maxPoints: Int = 600) {
        let timeline = Timeline(time: streams.time)
        self.timeline = timeline
        panels = ChartKind.panels(for: streams, isRun: isRun).map { kind in
            var values = kind.values(from: streams)
            if kind.smoothable, smoothing != .off {
                values = ChartSeries.smoothed(values, x: timeline.x, window: Double(smoothing.rawValue))
            }
            let points = ChartSeries.downsample(x: timeline.x, y: values, maxPoints: maxPoints)
            return Panel(kind: kind, values: values, points: points)
        }
    }
}

public extension ActivitySummary {
    var isRun: Bool { (type ?? "").lowercased().contains("run") }
}

// MARK: - Zoom

/// The visible stretch of a chart's time axis: pinch to zoom around a point, move to pan, and
/// never past the activity's ends or tighter than `minSpan` seconds.
public enum ChartZoom {
    public static let minSpan = 30.0

    /// `scale` < 1 zooms in (a pinch out), > 1 zooms out. The time under `anchor` stays put.
    public static func zoom(_ window: ClosedRange<Double>, by scale: Double, around anchor: Double,
                            within full: ClosedRange<Double>) -> ClosedRange<Double> {
        let fullSpan = full.upperBound - full.lowerBound
        let span = window.upperBound - window.lowerBound
        let newSpan = min(max(span * scale, min(minSpan, fullSpan)), fullSpan)
        let f = span > 0 ? (anchor - window.lowerBound) / span : 0.5
        let lo = anchor - f * newSpan
        return clamp(lo...(lo + newSpan), within: full)
    }

    /// Moves the window by `delta` seconds, stopping at the ends.
    public static func pan(_ window: ClosedRange<Double>, by delta: Double,
                           within full: ClosedRange<Double>) -> ClosedRange<Double> {
        clamp((window.lowerBound + delta)...(window.upperBound + delta), within: full)
    }

    /// A range widened by `fraction` of its span each side (for zooming to a selection), clamped.
    public static func padded(_ range: ClosedRange<Double>, by fraction: Double = 0.06,
                              within full: ClosedRange<Double>) -> ClosedRange<Double> {
        let span = max(range.upperBound - range.lowerBound, minSpan)
        let mid = (range.lowerBound + range.upperBound) / 2
        let half = span * (1 + 2 * fraction) / 2
        return clamp((mid - half)...(mid + half), within: full)
    }

    /// Whether a window is the whole activity (so there's nothing to reset).
    public static func isFull(_ window: ClosedRange<Double>, _ full: ClosedRange<Double>) -> Bool {
        window.lowerBound <= full.lowerBound + 0.5 && window.upperBound >= full.upperBound - 0.5
    }

    static func clamp(_ w: ClosedRange<Double>, within full: ClosedRange<Double>) -> ClosedRange<Double> {
        let span = min(w.upperBound - w.lowerBound, full.upperBound - full.lowerBound)
        var lo = w.lowerBound
        if lo < full.lowerBound { lo = full.lowerBound }
        if lo + span > full.upperBound { lo = full.upperBound - span }
        return lo...(lo + span)
    }
}

extension ChartStack.Panel {
    /// Points for a visible window at full resolution: just the samples in view (and one either
    /// side, so lines run to the edges), downsampled to `maxPoints`.
    public func points(in window: ClosedRange<Double>, timeline: Timeline, maxPoints: Int = 600) -> [ChartPoint] {
        let x = timeline.x
        guard !x.isEmpty, values.count == x.count else { return points }
        let lo = max((x.firstIndex { $0 >= window.lowerBound } ?? 0) - 1, 0)
        let hi = min((x.lastIndex { $0 <= window.upperBound } ?? x.count - 1) + 1, x.count - 1)
        guard hi > lo else { return [] }
        return ChartSeries.downsample(x: Array(x[lo...hi]), y: Array(values[lo...hi]), maxPoints: maxPoints)
    }
}
