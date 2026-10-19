import Foundation

/// One dig into W': W'bal falling from a local high to a local low.
public struct WbalEffort: Equatable, Sendable, Identifiable {
    /// Sample index where W'bal started falling, and where it bottomed out.
    public let startIndex: Int
    public let endIndex: Int
    /// Kilojoules.
    public let startKJ: Double
    public let lowKJ: Double

    public var spentKJ: Double { startKJ - lowKJ }
    public var id: Int { startIndex }
}

/// W'bal markers for an activity: the lowest point and each effort's kJ spent.
public struct WbalAnalysis: Equatable, Sendable {
    public let lowIndex: Int
    public let lowKJ: Double
    public let efforts: [WbalEffort]

    /// Finds efforts with a zigzag over the raw `w_bal` stream (joules): a fall only counts
    /// once W'bal has dropped by `threshold`, and it ends once W'bal has recovered by the same
    /// amount, so small surges and wobbles don't split one effort into several.
    /// The default threshold is 10% of the highest W'bal (about 3 kJ for a 31 kJ W').
    public static func analyse(wbal: [Double?], threshold: Double? = nil) -> WbalAnalysis? {
        let points = wbal.enumerated().compactMap { i, v in v.map { (i, $0) } }
        guard !points.isEmpty,
              let low = points.min(by: { $0.1 < $1.1 }),
              let top = points.max(by: { $0.1 < $1.1 })?.1 else { return nil }
        let t = threshold ?? max(top * 0.1, 1500)

        var efforts: [WbalEffort] = []
        var seekingLow = false
        // Positions in `points`.
        var high = 0
        var lowPos = 0

        func record() {
            // A long flat top before an effort would otherwise start the effort at the top's
            // first sample; start it where W'bal actually began to fall.
            let tolerance = t * 0.1
            var start = lowPos
            while start > high, points[start - 1].1 < points[high].1 - tolerance { start -= 1 }
            if start > high { start -= 1 }
            let a = points[start], b = points[lowPos]
            efforts.append(WbalEffort(startIndex: a.0, endIndex: b.0, startKJ: a.1 / 1000, lowKJ: b.1 / 1000))
        }

        for pos in 1..<points.count {
            let v = points[pos].1
            if seekingLow {
                if v < points[lowPos].1 { lowPos = pos }
                if v >= points[lowPos].1 + t {
                    record()
                    seekingLow = false
                    high = pos
                }
            } else {
                if v >= points[high].1 { high = pos }
                if v <= points[high].1 - t {
                    seekingLow = true
                    lowPos = pos
                }
            }
        }
        // Still digging when the recording stopped.
        if seekingLow, points[high].1 - points[lowPos].1 >= t { record() }

        return WbalAnalysis(lowIndex: low.0, lowKJ: low.1 / 1000, efforts: efforts)
    }

    /// The efforts worth labelling on the chart: the biggest few, in time order.
    public func labelled(max count: Int = 8) -> [WbalEffort] {
        Array(efforts.sorted { $0.spentKJ > $1.spentKJ }.prefix(count)).sorted { $0.startIndex < $1.startIndex }
    }
}
