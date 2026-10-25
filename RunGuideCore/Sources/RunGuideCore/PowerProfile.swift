import Foundation

// Monument's own power profile and W'bal model, kept separate from Intervals' so the two
// can be compared side by side. This is the starting point for profiling work: new fits
// (3-parameter, Pmax, durability/fatigue-adjusted CP and W') and new balance models plug in
// alongside the ones here.

/// A best-power curve from /athlete/{id}/power-curves: best average watts for each duration.
public struct PowerCurve: Decodable, Sendable, Equatable {
    public let secs: [Int]
    public let values: [Double?]
    public let startDateLocal: String?
    public let endDateLocal: String?
    /// Which curve this is when several were asked for ("42d", "1y", "all"…).
    public let id: String?
    /// The activity each best effort came from, if Intervals sends it.
    public let activityIDs: [String?]

    enum CodingKeys: String, CodingKey {
        case secs, values, watts, id
        case startDateLocal = "start_date_local"
        case endDateLocal = "end_date_local"
        case activityID = "activity_id"
    }

    public init(secs: [Int], values: [Double?], startDateLocal: String? = nil, endDateLocal: String? = nil,
                id: String? = nil, activityIDs: [String?] = []) {
        self.secs = secs
        self.values = values
        self.startDateLocal = startDateLocal
        self.endDateLocal = endDateLocal
        self.id = id
        self.activityIDs = activityIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        secs = try c.decodeIfPresent([Int].self, forKey: .secs) ?? []
        values = try c.decodeIfPresent([Double?].self, forKey: .values)
            ?? c.decodeIfPresent([Double?].self, forKey: .watts) ?? []
        startDateLocal = try c.decodeIfPresent(String.self, forKey: .startDateLocal)
        endDateLocal = try c.decodeIfPresent(String.self, forKey: .endDateLocal)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        if let ids = try? c.decodeIfPresent([FlexibleID?].self, forKey: .activityID) {
            activityIDs = ids.map { $0?.value }
        } else {
            activityIDs = []
        }
    }

    /// Decodes every curve in the endpoint's `{"list": [...]}` (or a bare array).
    public static func decodeAll(_ data: Data) throws -> [PowerCurve] {
        struct Wrapper: Decodable { let list: [PowerCurve]? }
        if let wrapped = try? JSONDecoder().decode(Wrapper.self, from: data), let list = wrapped.list {
            return list
        }
        return try JSONDecoder().decode([PowerCurve].self, from: data)
    }

    /// The activity behind the best effort at exactly `seconds`, if known.
    public func activity(at seconds: Int) -> String? {
        guard let i = secs.firstIndex(of: seconds), activityIDs.indices.contains(i) else { return nil }
        return activityIDs[i]
    }

    /// Decodes the endpoint's `{"list": [...]}` (or a bare array) and returns the first curve.
    public static func decodeFirst(_ data: Data) throws -> PowerCurve? {
        struct Wrapper: Decodable { let list: [PowerCurve]? }
        if let wrapped = try? JSONDecoder().decode(Wrapper.self, from: data), let list = wrapped.list {
            return list.first
        }
        return try JSONDecoder().decode([PowerCurve].self, from: data).first
    }

    /// Best power at exactly `seconds`. Interpolates only between close neighbours (within
    /// 20% of the duration), so a sparse curve doesn't invent efforts that weren't ridden.
    public func watts(at seconds: Int) -> Double? {
        let pairs = zip(secs, values).compactMap { s, v in v.map { (s, $0) } }
        if let exact = pairs.first(where: { $0.0 == seconds }) { return exact.1 }
        guard let below = pairs.last(where: { $0.0 < seconds }),
              let above = pairs.first(where: { $0.0 > seconds }),
              Double(above.0 - below.0) <= Double(seconds) * 0.2 else { return nil }
        let f = Double(seconds - below.0) / Double(above.0 - below.0)
        return below.1 + (above.1 - below.1) * f
    }
}

/// Critical power and W′ for one ride, and where they came from.
public struct PowerProfile: Equatable, Sendable {
    /// Watts.
    public let cp: Double
    /// Joules.
    public let wPrime: Double
    public let method: String
    /// The efforts the fit used: (seconds, watts).
    public let points: [Int: Double]
    /// How well the line fits the efforts, 0–1.
    public let r2: Double
    public let from: String?
    public let to: String?
    /// The full omni-domain model, when this profile came from an OmPD fit.
    public var omni: OmniDomain? = nil

    /// Durations the 2-parameter fit uses: 3 to 20 minutes, where the model holds up best.
    public static let fitDurations = [180, 240, 300, 420, 600, 720, 900, 1200]

    /// Two-parameter critical power model, fitted by least squares to best efforts:
    /// work done (P × t) = CP × t + W′. Needs at least three durations from the curve.
    /// Returns nil if the result isn't physiologically plausible (e.g. no hard efforts in the
    /// window, which pulls CP down and pushes W′ up).
    public static func fitTwoParameter(curve: PowerCurve, durations: [Int] = fitDurations) -> PowerProfile? {
        var points: [Int: Double] = [:]
        for d in durations { if let w = curve.watts(at: d), w > 0 { points[d] = w } }
        guard points.count >= 3 else { return nil }

        let ts = points.keys.sorted().map(Double.init)
        let work = points.keys.sorted().map { Double($0) * points[$0]! }
        let n = Double(ts.count)
        let meanT = ts.reduce(0, +) / n
        let meanW = work.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (t, w) in zip(ts, work) {
            sxy += (t - meanT) * (w - meanW)
            sxx += (t - meanT) * (t - meanT)
            syy += (w - meanW) * (w - meanW)
        }
        guard sxx > 0, syy > 0 else { return nil }
        let cp = sxy / sxx
        let wPrime = meanW - cp * meanT
        let r2 = (sxy * sxy) / (sxx * syy)
        guard cp > 50, cp < 700, wPrime > 3000, wPrime < 80000 else { return nil }

        return PowerProfile(cp: cp, wPrime: wPrime, method: "2-parameter CP, best 3–20 min efforts",
                            points: points, r2: r2,
                            from: curve.startDateLocal.map { String($0.prefix(10)) },
                            to: curve.endDateLocal.map { String($0.prefix(10)) })
    }
}

/// Ways to model W′ balance from power.
public enum WbalModel: String, CaseIterable, Sendable {
    /// Skiba's differential form (Skiba et al. 2015): above CP, W′ drains joule for joule;
    /// below CP it refills towards full at a rate proportional to how far below CP you are:
    /// dW/dt = (W′ − W) · (CP − P) / W′.
    case skibaDifferential

    /// W′ balance in joules for each sample, starting full.
    /// - Parameter time: seconds from the start for each sample. Gaps (pauses) count as
    ///   rest at 0 W, so W′ refills during a stop as it does in real life.
    public func balance(watts: [Double?], time: [Double], cp: Double, wPrime: Double) -> [Double?] {
        guard !watts.isEmpty, watts.count == time.count, cp > 0, wPrime > 0 else { return [] }
        var out = [Double?](repeating: nil, count: watts.count)
        var w = wPrime
        out[0] = w
        for i in 1..<watts.count {
            let dt = time[i] - time[i - 1]
            guard dt > 0 else { out[i] = w; continue }
            // A long gap is a stop: rest for the gap, then this sample's power for one second.
            let stopped = dt > Timeline.maxGap
            if stopped { w = Self.recover(w, power: 0, seconds: dt - 1, cp: cp, wPrime: wPrime) }
            let p = watts[i] ?? 0
            let step = stopped ? 1 : dt
            if p > cp {
                w -= (p - cp) * step
            } else {
                w = Self.recover(w, power: p, seconds: step, cp: cp, wPrime: wPrime)
            }
            out[i] = w
        }
        return out
    }

    /// Exact solution of the recovery equation over `seconds` at constant power below CP.
    static func recover(_ w: Double, power: Double, seconds: Double, cp: Double, wPrime: Double) -> Double {
        guard power < cp, w < wPrime else { return w }
        return wPrime - (wPrime - w) * exp(-(cp - power) * seconds / wPrime)
    }
}
