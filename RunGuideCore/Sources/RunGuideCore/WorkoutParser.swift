import Foundation

/// Parses sessions written in Intervals.icu's workout text format, e.g.
///
///     Warmup
///     - 2km 5:00-5:30/km Pace
///
///     Main set 5x
///     - 1km 4:00/km Pace
///     - Float 90s 5:00-5:30/km Pace
///
///     Cooldown
///     - 2km 5:00-5:30/km Pace
///
/// Rules:
/// - A step is a line starting with "-": optional cue text, then an amount,
///   then an optional target.
/// - Amounts: time as `90s`, `5m`, `1h`, `1m30s`, `1h30m`; distance as `2km`,
///   `2.5km`, `400mtr`, `1mi`. In Intervals `m` means minutes, but a bare `Xm`
///   with X ≥ 100 (e.g. `400m`) is treated as metres, since nobody means a
///   400-minute rep.
/// - A line ending in `Nx` starts a repeat block; it closes at a blank line
///   or the next header.
/// - Other short lines (≤ 3 words) are section headers used as labels.
///   Longer plain lines are treated as notes and ignored.
public enum WorkoutParser {

    struct RawStep {
        let cue: String?
        let end: StepEnd
        let target: String?
    }

    public static func parse(_ text: String, name: String = "Session") -> Workout {
        var steps: [Step] = []
        var section: String?
        var repeatCount: Int?
        var buffer: [RawStep] = []

        func add(_ label: String, _ raw: RawStep, _ kind: StepKind) {
            steps.append(Step(id: steps.count, label: label, end: raw.end, target: raw.target, kind: kind))
        }

        func flushRepeat() {
            guard let n = repeatCount else { return }
            if !buffer.isEmpty {
                for rep in 1...n {
                    for (j, raw) in buffer.enumerated() {
                        let label: String
                        if j == 0 {
                            label = raw.cue.map { "Rep \(rep) of \(n), \($0)" } ?? "Rep \(rep) of \(n)"
                        } else if let cue = raw.cue {
                            label = cue
                        } else {
                            label = buffer.count == 2 ? "Recovery" : "Rep \(rep) of \(n), part \(j + 1)"
                        }
                        add(label, raw, j == 0 ? .active : .rest)
                    }
                }
                section = nil
            }
            repeatCount = nil
            buffer = []
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushRepeat()
                continue
            }

            if line.hasPrefix("-") {
                let body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                guard let raw = parseStep(body) else { continue }
                if repeatCount != nil {
                    buffer.append(raw)
                } else {
                    add(raw.cue ?? section ?? "Step \(steps.count + 1)", raw, Self.kind(forSection: section))
                }
                continue
            }

            flushRepeat()
            if let n = repeatHeader(line) {
                repeatCount = n
                continue
            }
            if line.split(separator: " ").count <= 3 {
                section = line
            }
        }
        flushRepeat()

        return Workout(name: name, steps: steps)
    }

    // MARK: - Pieces

    static func kind(forSection section: String?) -> StepKind {
        let s = (section ?? "").lowercased()
        if s.contains("warm") { return .warmup }
        if s.contains("cool") { return .cooldown }
        if s.contains("recover") || s.contains("rest") { return .rest }
        return .active
    }

    static func repeatHeader(_ line: String) -> Int? {
        guard let match = firstMatch(#"^(?:.*?\s)?(\d+)\s*[xX]$"#, in: line),
              let n = Int(match[1]), n > 0 else { return nil }
        return n
    }

    static func parseStep(_ body: String) -> RawStep? {
        let tokens = body.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return nil }

        for (i, token) in tokens.enumerated() {
            guard let end = parseAmount(token) else { continue }
            let cue = tokens[..<i].joined(separator: " ")
            let rest = Array(tokens[(i + 1)...])
            return RawStep(cue: cue.isEmpty ? nil : cue, end: end, target: cleanTarget(rest))
        }

        // No amount found: an open step that ends when the runner taps Lap.
        return RawStep(cue: body, end: .open, target: nil)
    }

    static func parseAmount(_ token: String) -> StepEnd? {
        let t = token.lowercased()

        if let m = firstMatch(#"^(\d+(?:\.\d+)?)(km|mtr|mi)$"#, in: t), let value = Double(m[1]) {
            switch m[2] {
            case "km": return .distance(value * 1000)
            case "mi": return .distance(value * 1609.344)
            default: return .distance(value)
            }
        }

        if let m = firstMatch(#"^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$"#, in: t) {
            let h = Double(m[1]) ?? 0
            let min = Double(m[2]) ?? 0
            let s = Double(m[3]) ?? 0
            guard !m[1].isEmpty || !m[2].isEmpty || !m[3].isEmpty else { return nil }
            if m[1].isEmpty && m[3].isEmpty && min >= 100 {
                return .distance(min) // "400m" → 400 metres
            }
            let total = h * 3600 + min * 60 + s
            return total > 0 ? .time(total) : nil
        }

        return nil
    }

    static func cleanTarget(_ tokens: [String]) -> String? {
        var tokens = tokens
        let hasPace = tokens.contains { firstMatch(Speech.pacePattern, in: $0) != nil }
        if hasPace, let last = tokens.last, last.lowercased() == "pace" {
            tokens.removeLast()
        }
        let joined = tokens.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }
}

/// Returns capture groups (index 0 is the whole match); unmatched groups are "".
func firstMatch(_ pattern: String, in text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range) else { return nil }
    return (0..<match.numberOfRanges).map { i in
        guard let r = Range(match.range(at: i), in: text) else { return "" }
        return String(text[r])
    }
}
