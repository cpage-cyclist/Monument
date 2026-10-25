import Foundation

/// Turns numbers into phrases that sound natural when read aloud.
public enum Speech {

    static let pacePattern = #"(\d{1,2}):(\d{2})(?:-(\d{1,2}):(\d{2}))?(?:/(km|mi))?"#

    public static func distance(_ metres: Double) -> String {
        if metres >= 1000 {
            let km = (metres / 10).rounded() / 100
            if km == km.rounded() {
                let k = Int(km)
                return k == 1 ? "1 kilometre" : "\(k) kilometres"
            }
            return "\(trimmed(km)) kilometres"
        }
        let m = Int(metres.rounded())
        return m == 1 ? "1 metre" : "\(m) metres"
    }

    public static func duration(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        if t < 120 && t % 60 != 0 {
            return t == 1 ? "1 second" : "\(t) seconds"
        }
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        var parts: [String] = []
        if h > 0 { parts.append(h == 1 ? "1 hour" : "\(h) hours") }
        if m > 0 { parts.append(m == 1 ? "1 minute" : "\(m) minutes") }
        if s > 0 { parts.append("\(s) seconds") }
        return parts.isEmpty ? "0 seconds" : parts.joined(separator: " ")
    }

    /// 240 → "4 minutes", 298 → "4 58", 245 → "4 oh 5". `short` drops "minutes".
    public static func pace(_ secondsPerKm: Double, short: Bool = false) -> String {
        let total = Int(secondsPerKm.rounded())
        let m = total / 60, s = total % 60
        if s == 0 { return short ? "\(m)" : (m == 1 ? "1 minute" : "\(m) minutes") }
        if s < 10 { return "\(m) oh \(s)" }
        return "\(m) \(s)"
    }

    /// Seconds per km as a speed: 120 → "30 kilometres an hour".
    public static func speed(secondsPerKm: Double) -> String {
        guard secondsPerKm > 0 else { return "stopped" }
        return "\(Int((3600 / secondsPerKm).rounded())) kilometres an hour"
    }

    /// Speaks a target as written in the session.
    /// "4:00/km" → "4 minutes per kilometre", "5:00-5:30/km" → "5 to 5 30 per kilometre".
    public static func target(_ raw: String) -> String {
        if let m = firstMatch(pacePattern, in: raw),
           let a = Int(m[1]), let b = Int(m[2]) {
            let unit = m[5] == "mi" ? "per mile" : "per kilometre"
            let first = Double(a * 60 + b)
            if let c = Int(m[3]), let d = Int(m[4]) {
                let second = Double(c * 60 + d)
                return "\(pace(first, short: true)) to \(pace(second, short: true)) \(unit)"
            }
            return "\(pace(first)) \(unit)"
        }
        var text = raw
        text = text.replacingOccurrences(of: #"\bramp\b"#, with: "ramping", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"(\d+)-(\d+)rpm"#, with: "at $1 to $2 R P M", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(\d+)rpm"#, with: "at $1 R P M", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(\d+)w\b"#, with: "$1 watts", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\bZ(\d)\b"#, with: "zone $1", options: .regularExpression)
        text = text.replacingOccurrences(of: "LTHR", with: "threshold heart rate")
        text = text.replacingOccurrences(of: "HR", with: "heart rate")
        text = text.replacingOccurrences(of: "%", with: " percent")
        text = text.replacingOccurrences(of: "-", with: " to ")
        return text
    }

    /// "Rep 2. 1 kilometre at 4 minutes per kilometre."
    public static func intro(_ step: Step) -> String {
        var text = "\(step.label). "
        switch step.end {
        case .distance(let d): text += distance(d)
        case .time(let t): text += duration(t)
        case .open: text += "Lap when ready"
        }
        if let target = step.target { text += " at \(Speech.target(target))" }
        return text + "."
    }

    /// "Rep 2 of 5, Hill" → "Rep 2". Other labels unchanged.
    public static func shortLabel(_ label: String) -> String {
        if let m = firstMatch(#"^(Rep \d+) of \d+"#, in: label) { return m[1] }
        return label
    }

    static func trimmed(_ value: Double) -> String {
        var s = String(format: "%.2f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

/// Formats numbers for the screen.
public enum Format {
    /// 2895 → "48:15", 3723 → "1:02:03"
    public static func clock(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded(.down)))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 298 → "4:58"
    public static func pace(_ secondsPerKm: Double?) -> String {
        guard let p = secondsPerKm, p.isFinite, p > 0, p < 3600 else { return "–:––" }
        let t = Int(p.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    /// 10420 → "10.42 km"
    public static func km(_ metres: Double) -> String {
        String(format: "%.2f km", metres / 1000)
    }

    /// Distance left in a step: "1.23 km" or "450 m".
    public static func remainingDistance(_ metres: Double) -> String {
        metres >= 1000 ? String(format: "%.2f km", metres / 1000) : "\(Int(metres.rounded(.up))) m"
    }

    public static func amount(_ end: StepEnd) -> String {
        switch end {
        case .distance(let d): return d >= 1000 ? Speech.trimmed(d / 1000) + " km" : "\(Int(d)) m"
        case .time(let t): return clock(t)
        case .open: return "Lap when ready"
        }
    }
}
