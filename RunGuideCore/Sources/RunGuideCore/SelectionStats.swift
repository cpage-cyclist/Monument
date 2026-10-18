import Foundation

/// The breakdown for a stretch of an activity (a lap, a dragged range, a peak or the whole
/// thing), modelled on TrainingPeaks' lap panel. Everything is worked out from the raw
/// streams, so any selection gets the same figures.
public struct SelectionStats: Equatable, Sendable {
    public struct Range: Equatable, Sendable {
        public var min: Double
        public var avg: Double
        public var max: Double
    }

    /// Recorded seconds (pauses collapsed) and wall-clock seconds.
    public var duration: Double
    public var elapsed: Double
    /// Metres.
    public var distance: Double?

    public var power: Range?
    public var normalizedPower: Double?
    public var intensity: Double?
    public var load: Double?
    public var variabilityIndex: Double?
    /// Kilojoules.
    public var work: Double?
    public var wattsPerKg: Double?

    public var heartRate: Range?
    public var cadence: Range?
    /// km/h.
    public var speed: Range?
    /// Seconds per km (min is the fastest).
    public var pace: Range?
    public var elevation: Range?
    public var temperature: Range?

    public var elevationGain: Double?
    public var elevationLoss: Double?
    /// Metres climbed per hour.
    public var vam: Double?
    /// Percent, end altitude minus start over distance.
    public var grade: Double?
    /// Percent: how far power (or speed, for runs) per heartbeat fell from first half to second.
    public var decoupling: Double?

    /// Kilojoules.
    public var wbalStart: Double?
    public var wbalEnd: Double?
    public var wbalLow: Double?
    public var wbalUsed: Double? {
        guard let s = wbalStart, let l = wbalLow else { return nil }
        return max(s - l, 0)
    }

    public init(duration: Double, elapsed: Double) {
        self.duration = duration
        self.elapsed = elapsed
    }

    /// - Parameters:
    ///   - range: inclusive sample indexes.
    ///   - ftp: watts, for IF and load.
    ///   - weight: kg, for W/kg.
    public static func compute(streams: ActivityStreams, timeline: Timeline, range: ClosedRange<Int>,
                               ftp: Double?, weight: Double?, isRun: Bool) -> SelectionStats? {
        let n = timeline.count
        guard n > 0 else { return nil }
        let lo = Swift.max(range.lowerBound, 0)
        let hi = Swift.min(range.upperBound, n - 1)
        guard hi > lo else { return nil }

        let x = timeline.x
        // Seconds each sample stands for, with pauses already collapsed by the timeline.
        func dt(_ i: Int) -> Double { i > 0 ? x[i] - x[i - 1] : 0 }

        var stats = SelectionStats(duration: x[hi] - x[lo], elapsed: timeline.time[hi] - timeline.time[lo])

        if let d = streams[.distance], let a = d[safeIndex: lo] ?? nil, let b = d[safeIndex: hi] ?? nil, b >= a {
            stats.distance = b - a
        }

        // Power
        if let watts = streams[.watts], streams.has(.watts) {
            let slice = Array(watts[lo...hi])
            if let r = rangeOf(slice) {
                stats.power = r
                var joules = 0.0
                for i in (lo + 1)...hi { if let w = watts[i] { joules += w * dt(i) } }
                stats.work = joules / 1000
                let np = normalizedPower(watts, x: x, range: lo...hi) ?? r.avg
                stats.normalizedPower = np
                if r.avg > 0 { stats.variabilityIndex = np / r.avg }
                if let ftp, ftp > 0 {
                    let intensity = np / ftp
                    stats.intensity = intensity
                    stats.load = stats.duration * np * intensity / (ftp * 3600) * 100
                }
                if let weight, weight > 0 { stats.wattsPerKg = r.avg / weight }
            }
        }

        if let hr = streams[.heartrate], streams.has(.heartrate) {
            stats.heartRate = rangeOf(Array(hr[lo...hi]).map { $0.flatMap { $0 > 0 ? $0 : nil } })
        }
        if let cad = streams[.cadence], streams.has(.cadence) {
            // Average and minimum leave out coasting (zeros), as head units do.
            stats.cadence = rangeOf(Array(cad[lo...hi]).map { $0.flatMap { $0 > 0 ? $0 : nil } })
        }
        if let v = streams[.velocity], streams.has(.velocity) {
            let slice = Array(v[lo...hi])
            if var r = rangeOf(slice.map { $0.map { $0 * 3.6 } }) {
                if let d = stats.distance, stats.duration > 0 { r.avg = d / stats.duration * 3.6 }
                stats.speed = r
                if isRun {
                    let moving = slice.compactMap { $0 }.filter { $0 > 0.8 }
                    if let fast = moving.max(), let slow = moving.min(), r.avg > 0 {
                        stats.pace = Range(min: 1000 / fast, avg: 3600 / r.avg, max: 1000 / slow)
                    }
                }
            }
        }
        if let alt = streams[.altitude], streams.has(.altitude) {
            let slice = Array(alt[lo...hi])
            stats.elevation = rangeOf(slice)
            let (gain, loss) = climb(slice.compactMap { $0 })
            stats.elevationGain = gain
            stats.elevationLoss = loss
            if stats.duration >= 60 { stats.vam = gain / (stats.duration / 3600) }
            if let a = slice.first ?? nil, let b = slice.last ?? nil, let d = stats.distance, d > 50 {
                stats.grade = (b - a) / d * 100
            }
        }
        if let t = streams[.temp], streams.has(.temp) {
            stats.temperature = rangeOf(Array(t[lo...hi]))
        }

        if let wbal = streams[.wbal], streams.has(.wbal), streams.has(.watts) {
            let slice = Array(wbal[lo...hi]).compactMap { $0 }
            stats.wbalStart = slice.first.map { $0 / 1000 }
            stats.wbalEnd = slice.last.map { $0 / 1000 }
            stats.wbalLow = slice.min().map { $0 / 1000 }
        }

        stats.decoupling = decoupling(streams: streams, range: lo...hi, isRun: isRun)
        return stats
    }

    /// 30-second rolling average to the fourth power, averaged, fourth root (Coggan NP).
    /// Nil for selections under 30 seconds, where NP isn't meaningful.
    static func normalizedPower(_ watts: [Double?], x: [Double], range: ClosedRange<Int>) -> Double? {
        guard x[range.upperBound] - x[range.lowerBound] >= 30 else { return nil }
        let slice = Array(watts[range]).map { $0 ?? 0 }
        let xs = Array(x[range])
        let rolled = ChartSeries.smoothed(slice.map { Optional($0) }, x: xs, window: 30)
        var sum = 0.0, count = 0
        for i in rolled.indices where xs[i] - xs[0] >= 29 {
            if let r = rolled[i] { sum += pow(r, 4); count += 1 }
        }
        guard count > 0 else { return nil }
        return pow(sum / Double(count), 0.25)
    }

    /// Climbing and descending with a 1 m dead band, so GPS/baro noise doesn't add up.
    static func climb(_ altitude: [Double], threshold: Double = 1) -> (gain: Double, loss: Double) {
        guard var ref = altitude.first else { return (0, 0) }
        var gain = 0.0, loss = 0.0
        for a in altitude.dropFirst() {
            if a - ref >= threshold { gain += a - ref; ref = a }
            else if ref - a >= threshold { loss += ref - a; ref = a }
        }
        return (gain, loss)
    }

    /// Pw:HR (or Pa:HR for runs) decoupling between the two halves of the selection.
    static func decoupling(streams: ActivityStreams, range: ClosedRange<Int>, isRun: Bool) -> Double? {
        guard let hr = streams[.heartrate], streams.has(.heartrate) else { return nil }
        let outputType: StreamType = isRun || !streams.has(.watts) ? .velocity : .watts
        guard let output = streams[outputType], streams.has(outputType), range.count >= 600 else { return nil }
        let mid = (range.lowerBound + range.upperBound) / 2
        func ratio(_ r: ClosedRange<Int>) -> Double? {
            var o = 0.0, h = 0.0, n = 0
            for i in r {
                guard let ov = output[i], let hv = hr[i], hv > 0 else { continue }
                o += ov; h += hv; n += 1
            }
            guard n > 0, h > 0 else { return nil }
            return o / h
        }
        guard let first = ratio(range.lowerBound...mid), let second = ratio((mid + 1)...range.upperBound), first > 0 else { return nil }
        return (first - second) / first * 100
    }

    static func rangeOf(_ values: [Double?]) -> Range? {
        var lo = Double.infinity, hi = -Double.infinity, sum = 0.0, n = 0
        for v in values {
            guard let v else { continue }
            lo = Swift.min(lo, v); hi = Swift.max(hi, v); sum += v; n += 1
        }
        guard n > 0 else { return nil }
        return Range(min: lo, avg: sum / Double(n), max: hi)
    }
}

/// Best average power over set durations, and where it happened.
public struct PeakEffort: Equatable, Sendable, Identifiable {
    public let seconds: Int
    public let watts: Double
    /// Inclusive sample indexes.
    public let range: ClosedRange<Int>
    public var id: Int { seconds }

    public var label: String {
        seconds < 60 ? "\(seconds)s" : (seconds < 3600 ? "\(seconds / 60)m" : "\(seconds / 3600)h")
    }

    public static let standardDurations = [5, 15, 60, 300, 600, 1200, 3600]

    /// For each duration that fits in the activity, the highest average over that much
    /// recorded time (pauses collapsed).
    public static func find(watts: [Double?], timeline: Timeline,
                            durations: [Int] = standardDurations) -> [PeakEffort] {
        let x = timeline.x
        guard watts.count == x.count, x.count > 1 else { return [] }
        let w = watts.map { $0 ?? 0 }
        // Prefix sums of power × seconds, so any window's work is a subtraction.
        var energy = [0.0]
        energy.reserveCapacity(w.count)
        for i in 1..<w.count { energy.append(energy[i - 1] + w[i] * (x[i] - x[i - 1])) }

        var out: [PeakEffort] = []
        for d in durations where Double(d) <= timeline.duration {
            var best = -1.0, bestRange = 0...0
            var start = 0
            for end in 1..<x.count {
                while x[end] - x[start + 1] >= Double(d) { start += 1 }
                let span = x[end] - x[start]
                guard span >= Double(d) else { continue }
                let avg = (energy[end] - energy[start]) / span
                if avg > best { best = avg; bestRange = start...end }
            }
            if best >= 0 { out.append(PeakEffort(seconds: d, watts: best, range: bestRange)) }
        }
        return out
    }
}

extension Array {
    subscript(safeIndex i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
