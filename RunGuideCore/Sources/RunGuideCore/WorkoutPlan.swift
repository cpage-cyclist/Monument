import Foundation

// The workout builder's editable model. It reads and writes Intervals.icu workout text, which
// Intervals turns into steps, load and the file it syncs to a head unit. Sport is just a property
// of the workout, so the same builder serves rides, runs and anything else.
//
// Text rules followed here (as Intervals does): a step is a line starting with "- "; `m` always
// means minutes and metres are written `mtr`; a line ending in `Nx` starts a repeated block that
// a blank line closes; a plain line straight above a step names that block; other plain lines
// are notes.

public struct WorkoutPlan: Equatable, Sendable {
    public var name: String
    /// Intervals activity type: Ride, Run, VirtualRide, Swim, Workout…
    public var sport: String
    public var indoor: Bool
    /// Prose kept with the workout (shown above the steps).
    public var notes: String
    public var blocks: [PlanBlock]

    public init(name: String = "", sport: String = "Ride", indoor: Bool = false, notes: String = "",
                blocks: [PlanBlock] = []) {
        self.name = name
        self.sport = sport
        self.indoor = indoor
        self.notes = notes
        self.blocks = blocks
    }

    public var isRun: Bool { sport.lowercased().contains("run") }
}

/// A run of steps, optionally named and repeated. One level of repeats, as Intervals allows.
public struct PlanBlock: Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var title: String
    public var repeats: Int
    public var steps: [PlanStep]

    public init(title: String = "", repeats: Int = 1, steps: [PlanStep] = []) {
        self.title = title
        self.repeats = max(1, repeats)
        self.steps = steps
    }

    public static func == (a: PlanBlock, b: PlanBlock) -> Bool {
        a.title == b.title && a.repeats == b.repeats && a.steps == b.steps
    }
}

public struct PlanStep: Equatable, Identifiable, Sendable {
    public var id = UUID()
    /// Free text before the length: the cue ("Seated climb", "Easy by feel, RPE 3").
    public var cue: String
    public var length: PlanLength
    public var target: PlanTarget?
    public var cadence: CadenceRange?
    /// Anything after the length that isn't understood, kept so editing never loses it.
    public var extra: String

    public init(cue: String = "", length: PlanLength = .time(300), target: PlanTarget? = nil,
                cadence: CadenceRange? = nil, extra: String = "") {
        self.cue = cue
        self.length = length
        self.target = target
        self.cadence = cadence
        self.extra = extra
    }

    public static func == (a: PlanStep, b: PlanStep) -> Bool {
        a.cue == b.cue && a.length == b.length && a.target == b.target && a.cadence == b.cadence && a.extra == b.extra
    }
}

public enum PlanLength: Equatable, Hashable, Sendable {
    /// Seconds.
    case time(Double)
    /// Metres.
    case distance(Double)
}

public struct CadenceRange: Equatable, Hashable, Sendable {
    public var low: Int
    public var high: Int?
    public init(low: Int, high: Int? = nil) { self.low = low; self.high = high }
}

/// What a step aims for. `low`/`high` are percentages, watts, zone numbers or seconds per km,
/// depending on `metric` and `mode`. A single value has no `high`.
public struct PlanTarget: Equatable, Hashable, Sendable {
    public enum Metric: String, CaseIterable, Sendable {
        case power, heartRate, lthr, pace
    }
    public enum Mode: String, CaseIterable, Sendable {
        /// % of FTP, max HR, LTHR or threshold pace.
        case percent
        /// Watts for power, seconds per km for pace.
        case absolute
        case zone
    }

    public var metric: Metric
    public var mode: Mode
    public var low: Double
    public var high: Double?
    public var ramp: Bool

    public init(metric: Metric, mode: Mode, low: Double, high: Double? = nil, ramp: Bool = false) {
        self.metric = metric
        self.mode = mode
        self.low = low
        self.high = high
        self.ramp = ramp
    }

    public var isRange: Bool { high != nil && high != low }
}

// MARK: - Writing Intervals text

extension WorkoutPlan {
    public var text: String {
        var parts: [String] = []
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { parts.append(notes) }
        for block in blocks where !block.steps.isEmpty {
            var lines: [String] = []
            let title = block.title.trimmingCharacters(in: .whitespaces)
            if block.repeats > 1 {
                lines.append(title.isEmpty ? "\(block.repeats)x" : "\(title) \(block.repeats)x")
            } else if !title.isEmpty {
                lines.append(title)
            }
            lines += block.steps.map { "- " + $0.text }
            parts.append(lines.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}

extension PlanStep {
    public var text: String {
        var words: [String] = []
        let cue = cue.trimmingCharacters(in: .whitespaces)
        if !cue.isEmpty { words.append(cue) }
        if length != .time(0) { words.append(length.text) }
        if let target { words.append(target.text) }
        if let cadence { words.append(cadence.text) }
        let extra = extra.trimmingCharacters(in: .whitespaces)
        if !extra.isEmpty { words.append(extra) }
        return words.joined(separator: " ")
    }
}

extension PlanLength {
    public var text: String {
        switch self {
        case .time(let seconds):
            let s = Int(seconds.rounded())
            let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
            var out = ""
            if h > 0 { out += "\(h)h" }
            if m > 0 { out += "\(m)m" }
            if sec > 0 || out.isEmpty { out += "\(sec)s" }
            return out
        case .distance(let metres):
            if metres >= 1000, (metres / 100).rounded() == metres / 100 {
                return PlanFormat.number(metres / 1000) + "km"
            }
            return "\(Int(metres.rounded()))mtr"
        }
    }
}

extension CadenceRange {
    public var text: String { high.map { "\(low)-\($0)rpm" } ?? "\(low)rpm" }
}

extension PlanTarget {
    public var text: String {
        let ramp = self.ramp ? "ramp " : ""
        let range: (Double, Double?, (Double) -> String) -> String = { low, high, f in
            guard let high, high != low else { return f(low) }
            return f(low) + "-" + f(high)
        }
        switch (metric, mode) {
        case (_, .zone):
            let zones = high.map { $0 != low ? "Z\(Int(low))-Z\(Int($0))" : "Z\(Int(low))" } ?? "Z\(Int(low))"
            return ramp + zones + metric.suffix
        case (.power, .absolute):
            return ramp + range(low, high) { "\(Int($0.rounded()))" } + "w"
        case (.pace, .absolute):
            return ramp + range(low, high, PlanFormat.pace) + "/km Pace"
        case (_, _):
            return ramp + range(low, high, PlanFormat.number) + "%" + metric.suffix
        }
    }
}

extension PlanTarget.Metric {
    /// The word that follows the number in Intervals text.
    var suffix: String {
        switch self {
        case .power: ""
        case .heartRate: " HR"
        case .lthr: " LTHR"
        case .pace: " Pace"
        }
    }
}

public enum PlanFormat {
    /// 95 → "95", 2.5 → "2.5".
    public static func number(_ v: Double) -> String {
        v.rounded() == v ? "\(Int(v))" : String(format: "%g", v)
    }

    /// Seconds per km as "4:20".
    public static func pace(_ secondsPerKm: Double) -> String {
        let s = Int(secondsPerKm.rounded())
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

// MARK: - Reading Intervals text

extension WorkoutPlan {
    public init(text: String, name: String = "", sport: String = "Ride", indoor: Bool = false) {
        self.init(name: name, sport: sport, indoor: indoor)
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }

        var notes: [String] = []
        var current: PlanBlock?
        /// The current block is a repeat, so it stays open until a blank line.
        var inRepeat = false

        func close() {
            if let block = current, !block.steps.isEmpty { blocks.append(block) }
            current = nil
            inRepeat = false
        }

        var afterBlank = false
        for (i, line) in lines.enumerated() {
            if line.isEmpty {
                close()
                afterBlank = true
                continue
            }
            defer { afterBlank = false }
            if line.hasPrefix("-") {
                let body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                let step = PlanStep(text: body)
                if current == nil { current = PlanBlock() }
                current?.steps.append(step)
                continue
            }
            // A plain line: a repeat header, a block name (a step follows straight on), or a note.
            let nextIsStep = lines.indices.contains(i + 1) && lines[i + 1].hasPrefix("-")
            if let (title, n) = Self.repeatHeader(line) {
                close()
                current = PlanBlock(title: title, repeats: n)
                inRepeat = true
            } else if nextIsStep {
                close()
                current = PlanBlock(title: line)
            } else {
                if !inRepeat { close() }
                if afterBlank, !notes.isEmpty { notes.append("") }
                notes.append(line)
            }
        }
        close()
        self.notes = notes.joined(separator: "\n")
    }

    /// "Main set 3x" → ("Main set", 3); "8x" → ("", 8).
    static func repeatHeader(_ line: String) -> (String, Int)? {
        guard let m = firstMatch(#"^(.*?)\s*(\d+)\s*[xX]$"#, in: line), let n = Int(m[2]), n > 0 else { return nil }
        return (m[1].trimmingCharacters(in: .whitespaces), n)
    }
}

extension PlanStep {
    /// Parses a step line without its leading "- ".
    public init(text body: String) {
        self.init()
        let tokens = body.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let at = tokens.firstIndex(where: { PlanLength(token: $0) != nil }),
              let length = PlanLength(token: tokens[at]) else {
            // No length: keep it all as the cue of an open-ended step (Intervals shows it as text).
            cue = body
            self.length = .time(0)
            return
        }
        cue = tokens[..<at].joined(separator: " ")
        self.length = length

        var rest = Array(tokens[(at + 1)...])
        var extra: [String] = []
        var ramp = false
        while !rest.isEmpty {
            let token = rest.removeFirst()
            let lower = token.lowercased()
            if lower == "ramp" { ramp = true; continue }
            if cadence == nil, let c = CadenceRange(token: lower) { cadence = c; continue }
            if target == nil, var read = PlanTarget.read(token: token, next: rest.first) {
                if read.consumesNext { rest.removeFirst() }
                read.target.ramp = ramp
                target = read.target
                continue
            }
            extra.append(token)
        }
        if ramp, target == nil { extra.insert("ramp", at: 0) }
        self.extra = extra.joined(separator: " ")
    }
}

extension PlanLength {
    init?(token: String) {
        let t = token.lowercased()
        if let m = firstMatch(#"^(\d+(?:\.\d+)?)(km|mtr|mi)$"#, in: t), let v = Double(m[1]) {
            switch m[2] {
            case "km": self = .distance(v * 1000)
            case "mi": self = .distance(v * 1609.344)
            default: self = .distance(v)
            }
            return
        }
        guard let m = firstMatch(#"^(?:(\d+(?:\.\d+)?)h)?(?:(\d+(?:\.\d+)?)m)?(?:(\d+(?:\.\d+)?)s)?$"#, in: t),
              !(m[1].isEmpty && m[2].isEmpty && m[3].isEmpty) else { return nil }
        let total = (Double(m[1]) ?? 0) * 3600 + (Double(m[2]) ?? 0) * 60 + (Double(m[3]) ?? 0)
        guard total > 0 else { return nil }
        self = .time(total)
    }

    public var seconds: Double? { if case .time(let s) = self { return s } else { return nil } }
    public var metres: Double? { if case .distance(let d) = self { return d } else { return nil } }
}

extension CadenceRange {
    init?(token: String) {
        guard let m = firstMatch(#"^(\d+)(?:-(\d+))?rpm$"#, in: token), let low = Int(m[1]) else { return nil }
        self.init(low: low, high: Int(m[2]))
    }
}

extension PlanTarget {
    /// A target read from a token, and whether it took the word after it (HR, LTHR, Pace).
    struct Read { var target: PlanTarget; let consumesNext: Bool }

    static func metric(after next: String?) -> Metric? {
        switch next?.lowercased() {
        case "hr": .heartRate
        case "lthr": .lthr
        case "pace": .pace
        default: nil
        }
    }

    static func read(token: String, next: String?) -> Read? {
        let lower = token.lowercased()
        let following = metric(after: next)
        let metric = following ?? .power

        if let m = firstMatch(#"^(\d+(?:\.\d+)?)(?:-(\d+(?:\.\d+)?))?%$"#, in: lower), let low = Double(m[1]) {
            return Read(target: PlanTarget(metric: metric, mode: .percent, low: low, high: Double(m[2])),
                        consumesNext: following != nil)
        }
        if let m = firstMatch(#"^z(\d)(?:-z?(\d))?$"#, in: lower), let low = Double(m[1]) {
            return Read(target: PlanTarget(metric: metric, mode: .zone, low: low, high: Double(m[2])),
                        consumesNext: following != nil)
        }
        if let m = firstMatch(#"^(\d+)(?:-(\d+))?w$"#, in: lower), let low = Double(m[1]) {
            return Read(target: PlanTarget(metric: .power, mode: .absolute, low: low, high: Double(m[2])),
                        consumesNext: false)
        }
        if let m = firstMatch(#"^(\d+):(\d\d)(?:-(\d+):(\d\d))?/(km|mi)$"#, in: lower),
           let mm = Double(m[1]), let ss = Double(m[2]) {
            let perKm = m[5] == "mi" ? 1 / 1.609344 : 1.0
            let low = (mm * 60 + ss) * perKm
            var high: Double?
            if let hm = Double(m[3]), let hs = Double(m[4]) { high = (hm * 60 + hs) * perKm }
            return Read(target: PlanTarget(metric: .pace, mode: .absolute, low: low, high: high),
                        consumesNext: following == .pace)
        }
        return nil
    }
}

// MARK: - Shape, time and load

/// The athlete's thresholds, for turning watts and paces into intensity and distances into time.
public struct PlanContext: Equatable, Sendable {
    public var ftp: Double?
    /// Seconds per km.
    public var thresholdPace: Double?
    public init(ftp: Double? = nil, thresholdPace: Double? = nil) {
        self.ftp = ftp
        self.thresholdPace = thresholdPace
    }

    var ftpOrDefault: Double { ftp ?? 250 }
    var thresholdPaceOrDefault: Double { thresholdPace ?? 270 }
}

/// One step as drawn: where it sits in time and its intensity (1.0 = threshold) at each end.
public struct PlanSegment: Equatable, Identifiable, Sendable {
    public let id: Int
    public let stepId: UUID
    public let blockId: UUID
    public let start: Double
    public let duration: Double
    public let from: Double
    public let to: Double
    public let hasTarget: Bool
    public var end: Double { start + duration }
}

extension PlanTarget {
    /// Rough midpoints of Intervals' default zones, as a fraction of threshold.
    static let zoneIntensity: [Double] = [0.50, 0.65, 0.83, 0.98, 1.13, 1.35, 1.60]

    /// Intensity at the low and high ends, as a fraction of threshold.
    public func intensity(_ context: PlanContext) -> (low: Double, high: Double) {
        func one(_ v: Double) -> Double {
            switch (metric, mode) {
            case (_, .zone):
                let i = min(max(Int(v) - 1, 0), Self.zoneIntensity.count - 1)
                return Self.zoneIntensity[i]
            case (.power, .absolute): return v / context.ftpOrDefault
            case (.pace, .absolute): return context.thresholdPaceOrDefault / max(v, 1)
            // Threshold HR sits at about 90% of max.
            case (.heartRate, _): return v / 100 / 0.9
            default: return v / 100
            }
        }
        let a = one(low), b = one(high ?? low)
        // Faster pace (fewer seconds) is harder, so order by intensity.
        return (min(a, b), max(a, b))
    }
}

extension PlanStep {
    /// Time the step takes; distance steps are timed from their pace target, else a typical speed.
    public func seconds(sport: String, _ context: PlanContext) -> Double {
        switch length {
        case .time(let s): return s
        case .distance(let metres):
            return metres / 1000 * secondsPerKm(sport: sport, context)
        }
    }

    func secondsPerKm(sport: String, _ context: PlanContext) -> Double {
        if let t = target, t.metric == .pace {
            switch t.mode {
            case .absolute: return (t.low + (t.high ?? t.low)) / 2
            case .percent, .zone:
                let i = t.intensity(context)
                return context.thresholdPaceOrDefault / max((i.low + i.high) / 2, 0.3)
            }
        }
        // No pace to go on: easy running, or about 30 km/h on the bike.
        return sport.lowercased().contains("run") ? context.thresholdPaceOrDefault / 0.8 : 120
    }
}

extension WorkoutPlan {
    /// Every step in order with repeats expanded.
    public func segments(_ context: PlanContext = PlanContext()) -> [PlanSegment] {
        var out: [PlanSegment] = []
        var t = 0.0
        for block in blocks {
            for _ in 0..<block.repeats {
                for step in block.steps {
                    let d = step.seconds(sport: sport, context)
                    let i = step.target?.intensity(context)
                    let flat = i.map { ($0.low + $0.high) / 2 } ?? 0.5
                    let ramp = step.target?.ramp == true
                    out.append(PlanSegment(id: out.count, stepId: step.id, blockId: block.id, start: t, duration: d,
                                           from: ramp ? (i?.low ?? flat) : flat, to: ramp ? (i?.high ?? flat) : flat,
                                           hasTarget: step.target != nil))
                    t += d
                }
            }
        }
        return out
    }

    public func totalSeconds(_ context: PlanContext = PlanContext()) -> Double {
        segments(context).reduce(0) { $0 + $1.duration }
    }

    /// Training-stress style estimate: hours × intensity² × 100. Steps without a target count as
    /// easy (50%). Intervals works out the real figure when the workout is saved.
    public func estimatedLoad(_ context: PlanContext = PlanContext()) -> Double {
        segments(context).reduce(0) { total, s in
            // Mean of intensity² along a straight ramp.
            let sq = (s.from * s.from + s.from * s.to + s.to * s.to) / 3
            return total + s.duration / 3600 * sq * 100
        }
    }

    /// Finds a step anywhere in the plan.
    public func step(_ id: UUID) -> PlanStep? {
        blocks.lazy.flatMap(\.steps).first { $0.id == id }
    }
}

// MARK: - Intervals library

/// A folder or training plan from /athlete/{id}/folders, with its workouts.
public struct LibraryFolder: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String?
    /// FOLDER or PLAN.
    public let type: String?
    public let children: [LibraryWorkout]?

    public init(id: Int, name: String?, type: String? = "FOLDER", children: [LibraryWorkout]? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.children = children
    }

    public var workouts: [LibraryWorkout] { children ?? [] }
}

/// A saved workout in the library.
public struct LibraryWorkout: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let folderId: Int?
    public let name: String?
    public let description: String?
    public let type: String?
    /// Seconds.
    public let movingTime: Double?
    public let trainingLoad: Double?
    public let indoor: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, description, type, indoor
        case folderId = "folder_id"
        case movingTime = "moving_time"
        case trainingLoad = "icu_training_load"
    }

    public init(id: Int, folderId: Int?, name: String?, description: String?, type: String?,
                movingTime: Double? = nil, trainingLoad: Double? = nil, indoor: Bool? = nil) {
        self.id = id
        self.folderId = folderId
        self.name = name
        self.description = description
        self.type = type
        self.movingTime = movingTime
        self.trainingLoad = trainingLoad
        self.indoor = indoor
    }
}

extension WorkoutPlan {
    public init(event: CalendarEvent) {
        self.init(text: event.description ?? "", name: event.name ?? "", sport: event.type ?? "Ride",
                  indoor: event.indoor ?? false)
    }

    public init(library w: LibraryWorkout) {
        self.init(text: w.description ?? "", name: w.name ?? "", sport: w.type ?? "Ride", indoor: w.indoor ?? false)
    }

    /// The fields Intervals takes for a workout, as a calendar entry or library workout.
    public func intervalsFields() -> [String: Any] {
        ["name": name.trimmingCharacters(in: .whitespaces).isEmpty ? "Workout" : name,
         "description": text,
         "type": sport,
         "indoor": indoor]
    }
}
