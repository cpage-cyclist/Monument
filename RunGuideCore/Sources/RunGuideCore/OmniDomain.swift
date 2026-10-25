import Foundation

/// The omni-domain power-duration model (OmPD; Puchowicz, Baker & Clarke 2020): one curve from a
/// sprint to several hours. Up to TCPmax (30 min) it's the critical power curve with W′'s rate of
/// spending capped by maximal power; beyond it, power falls away from CP log-linearly:
///
///     P(t) = W′/t · (1 − e^(−t·(Pmax − CP)/W′)) + CP                     t ≤ TCPmax
///     P(t) = W′/t · (1 − e^(−t·(Pmax − CP)/W′)) + CP − A · ln(t / TCPmax)  t > TCPmax
///
/// Fitted to the best-power curve, which is an envelope of best efforts rather than tests to
/// exhaustion, so the values describe what's been ridden in the window.
public struct OmniDomain: Equatable, Sendable {
    /// Watts.
    public let pmax: Double
    /// Watts.
    public let cp: Double
    /// Joules.
    public let wPrime: Double
    /// Watts lost per e-fold of duration beyond TCPmax.
    public let a: Double
    /// Whether the curve had efforts past TCPmax, so `a` was fitted rather than assumed 0.
    public let fittedLong: Bool

    public static let tcpMax = 1800.0

    public init(pmax: Double, cp: Double, wPrime: Double, a: Double, fittedLong: Bool = true) {
        self.pmax = pmax
        self.cp = cp
        self.wPrime = wPrime
        self.a = a
        self.fittedLong = fittedLong
    }

    public func power(at t: Double) -> Double {
        guard t > 0 else { return pmax }
        let base = wPrime / t * (1 - exp(-t * (pmax - cp) / wPrime)) + cp
        return t > Self.tcpMax ? base - a * log(t / Self.tcpMax) : base
    }

    /// Modelled one-hour power: Monument's FTP.
    public var ftp: Double { power(at: 3600) }

    /// Durations sampled from the curve for fitting, spread evenly on a log scale from 1 s to 2 h.
    public static let fitDurations = [1, 2, 3, 5, 8, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240, 300, 420,
                                      600, 720, 900, 1200, 1500, 1800, 2400, 3000, 3600, 4500, 5400, 7200]

    /// Fits the model to a best-power curve by least squares on relative error, so a sprint and a
    /// two-hour effort count alike. Needs efforts under 30 s and over 10 min. Returns nil if the
    /// curve is too sparse or the result isn't plausible.
    public static func fit(curve: PowerCurve) -> (model: OmniDomain, points: [Int: Double], r2: Double)? {
        var points: [Int: Double] = [:]
        for d in fitDurations { if let w = curve.watts(at: d), w > 0 { points[d] = w } }
        guard points.count >= 6,
              points.keys.contains(where: { $0 <= 30 }),
              points.keys.contains(where: { $0 >= 600 }) else { return nil }
        let samples = points.sorted { $0.key < $1.key }.map { (Double($0.key), $0.value) }
        let hasLong = samples.contains { $0.0 > tcpMax }

        // Starting point: sprint power for Pmax, a two-parameter fit for CP and W′.
        let peak = samples.filter { $0.0 <= 5 }.map(\.1).max() ?? samples[0].1
        let two = PowerProfile.fitTwoParameter(curve: curve)
        let cp0 = two?.cp ?? (curve.watts(at: 1200) ?? samples.last!.1) * 0.95
        let w0 = two?.wPrime ?? 20000
        var a0 = 0.0
        if hasLong {
            let start = OmniDomain(pmax: peak, cp: cp0, wPrime: w0, a: 0)
            let drops = samples.filter { $0.0 > tcpMax }.map { (start.power(at: $0.0) - $0.1) / log($0.0 / tcpMax) }
            a0 = max(0, drops.reduce(0, +) / Double(drops.count))
        }

        func model(_ x: [Double]) -> OmniDomain {
            OmniDomain(pmax: x[0], cp: x[1], wPrime: x[2], a: hasLong ? x[3] : 0, fittedLong: hasLong)
        }
        func cost(_ x: [Double]) -> Double {
            let m = model(x)
            // Keep to the physically meaningful region.
            guard m.cp > 30, m.wPrime > 500, m.pmax > m.cp + 20, m.a >= 0 else { return .infinity }
            return samples.reduce(0) { sum, s in
                let e = (m.power(at: s.0) - s.1) / s.1
                return sum + e * e
            }
        }

        var start = [peak, cp0, w0]
        if hasLong { start.append(a0) }
        let best = NelderMead.minimise(cost, from: start, steps: start.map { max(abs($0) * 0.1, 1) })
        let m = model(best)

        // R² on watts.
        let mean = samples.map(\.1).reduce(0, +) / Double(samples.count)
        let ssTot = samples.reduce(0) { $0 + ($1.1 - mean) * ($1.1 - mean) }
        let ssRes = samples.reduce(0) { $0 + pow(m.power(at: $1.0) - $1.1, 2) }
        let r2 = ssTot > 0 ? 1 - ssRes / ssTot : 0

        guard m.cp > 80, m.cp < 650, m.wPrime > 3000, m.wPrime < 60000,
              m.pmax > m.cp * 1.5, m.pmax < 3000, m.a < m.cp * 0.25, r2 > 0.9 else { return nil }
        return (m, points, r2)
    }
}

/// A small Nelder–Mead simplex minimiser: no gradients needed, fine for a handful of parameters.
enum NelderMead {
    static func minimise(_ f: ([Double]) -> Double, from x0: [Double], steps: [Double],
                         iterations: Int = 4000, tolerance: Double = 1e-12) -> [Double] {
        let n = x0.count
        var simplex: [[Double]] = [x0]
        for i in 0..<n {
            var p = x0
            p[i] += steps[i]
            simplex.append(p)
        }
        var values = simplex.map(f)

        for _ in 0..<iterations {
            let order = values.indices.sorted { values[$0] < values[$1] }
            simplex = order.map { simplex[$0] }
            values = order.map { values[$0] }
            if abs(values[n] - values[0]) < tolerance * (abs(values[0]) + tolerance) { break }

            // Centroid of all but the worst.
            var c = [Double](repeating: 0, count: n)
            for p in simplex.dropLast() { for j in 0..<n { c[j] += p[j] / Double(n) } }
            func towards(_ k: Double) -> [Double] { (0..<n).map { c[$0] + k * (simplex[n][$0] - c[$0]) } }

            let reflected = towards(-1), fr = f(reflected)
            if fr < values[0] {
                let expanded = towards(-2), fe = f(expanded)
                (simplex[n], values[n]) = fe < fr ? (expanded, fe) : (reflected, fr)
            } else if fr < values[n - 1] {
                (simplex[n], values[n]) = (reflected, fr)
            } else {
                let contracted = fr < values[n] ? towards(-0.5) : towards(0.5)
                let fc = f(contracted)
                if fc < min(fr, values[n]) {
                    (simplex[n], values[n]) = (contracted, fc)
                } else {
                    // Shrink towards the best.
                    for i in 1...n {
                        simplex[i] = (0..<n).map { simplex[0][$0] + 0.5 * (simplex[i][$0] - simplex[0][$0]) }
                        values[i] = f(simplex[i])
                    }
                }
            }
        }
        let best = values.indices.min { values[$0] < values[$1] } ?? 0
        return simplex[best]
    }
}

extension PowerProfile {
    /// CP and W′ from an OmPD fit, so W′ balance can use them. Falls back to nothing (the caller then
    /// tries the two-parameter fit).
    public static func fitOmniDomain(curve: PowerCurve) -> PowerProfile? {
        guard let fit = OmniDomain.fit(curve: curve) else { return nil }
        var p = PowerProfile(cp: fit.model.cp, wPrime: fit.model.wPrime,
                             method: "Omni-domain (OmPD), best efforts 1 s – 2 h",
                             points: fit.points, r2: fit.r2,
                             from: curve.startDateLocal.map { String($0.prefix(10)) },
                             to: curve.endDateLocal.map { String($0.prefix(10)) })
        p.omni = fit.model
        return p
    }

    /// OmPD if it fits, else the two-parameter model.
    public static func fitBest(curve: PowerCurve) -> PowerProfile? {
        fitOmniDomain(curve: curve) ?? fitTwoParameter(curve: curve)
    }

    /// Monument's FTP: OmPD's modelled hour power, or CP from the two-parameter fit.
    public var ftp: Double { omni?.ftp ?? cp }
}
