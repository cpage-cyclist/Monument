import Foundation

// Calendar, fitness and the Today/Week layouts built from them.

/// One entry from /athlete/{id}/events: a planned workout, race, note or similar.
public struct CalendarEvent: Decodable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let startDateLocal: String?
    /// WORKOUT, RACE_A/B/C, NOTE, HOLIDAY, SICK, INJURED, TARGET…
    public let category: String?
    public let type: String?
    public let name: String?
    public let description: String?
    /// Seconds.
    public let movingTime: Double?
    public let trainingLoad: Double?
    /// Percent of FTP.
    public let intensity: Double?
    public let indoor: Bool?

    enum CodingKeys: String, CodingKey {
        case id, category, type, name, description, indoor
        case startDateLocal = "start_date_local"
        case movingTime = "moving_time"
        case trainingLoad = "icu_training_load"
        case intensity = "icu_intensity"
    }

    public init(id: Int, startDateLocal: String?, category: String?, type: String?, name: String?,
                description: String?, movingTime: Double? = nil, trainingLoad: Double? = nil,
                intensity: Double? = nil, indoor: Bool? = nil) {
        self.id = id
        self.startDateLocal = startDateLocal
        self.category = category
        self.type = type
        self.name = name
        self.description = description
        self.movingTime = movingTime
        self.trainingLoad = trainingLoad
        self.intensity = intensity
        self.indoor = indoor
    }

    /// "2026-10-19".
    public var day: String { String((startDateLocal ?? "").prefix(10)) }
    public var isWorkout: Bool { (category ?? "WORKOUT") == "WORKOUT" }
    public var isRace: Bool { (category ?? "").hasPrefix("RACE") }
    public var isNote: Bool { category == "NOTE" }
    public var isRun: Bool { (type ?? "").lowercased().contains("run") }
    /// Something to train: a workout or a race.
    public var isSession: Bool { isWorkout || isRace }
}

/// One day's fitness from /athlete/{id}/wellness.
public struct WellnessDay: Decodable, Hashable, Sendable {
    /// The day, "2026-10-19".
    public let id: String
    public let ctl: Double?
    public let atl: Double?
    public let rampRate: Double?

    public init(id: String, ctl: Double?, atl: Double?, rampRate: Double? = nil) {
        self.id = id
        self.ctl = ctl
        self.atl = atl
        self.rampRate = rampRate
    }

    /// Form (TSB) = fitness − fatigue.
    public var form: Double? {
        guard let ctl, let atl else { return nil }
        return ctl - atl
    }

    /// The latest day with fitness numbers, on or before `today`.
    public static func latest(in days: [WellnessDay], onOrBefore today: String) -> WellnessDay? {
        days.filter { $0.id <= today && $0.ctl != nil }.max { $0.id < $1.id }
    }

    /// Days with fitness numbers in the last `count` days up to `today`, oldest first.
    public static func recent(_ days: [WellnessDay], count: Int, today: String,
                              calendar: Calendar = .current) -> [WellnessDay] {
        guard let end = IntervalsDates.parseLocal(today + "T12:00:00"),
              let start = calendar.date(byAdding: .day, value: -(count - 1), to: end) else { return [] }
        let first = IntervalsDates.day(start)
        return days.filter { $0.id >= first && $0.id <= today && $0.ctl != nil && $0.atl != nil }
            .sorted { $0.id < $1.id }
    }

    /// Intervals' form zones (TSB).
    public enum FormZone: String, Sendable {
        case transition = "Transition", fresh = "Fresh", grey = "Grey zone", optimal = "Optimal", highRisk = "High risk"

        public init(form: Double) {
            switch form {
            case 25...: self = .transition
            case 5..<25: self = .fresh
            case -10..<5: self = .grey
            case -30 ..< -10: self = .optimal
            default: self = .highRisk
            }
        }
    }

    public var formZone: FormZone? { form.map(FormZone.init(form:)) }
}

/// Seven days centred on a date: three either side.
public struct DayWindow: Equatable, Sendable {
    public let center: String
    public let days: [String]

    public init(center: Date, calendar: Calendar = .current) {
        self.center = IntervalsDates.day(center)
        days = (-3...3).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: center).map(IntervalsDates.day)
        }
    }

    public var first: String { days.first ?? center }
    public var last: String { days.last ?? center }

    /// The window `weeks` weeks earlier or later.
    public func shifted(byWeeks weeks: Int, calendar: Calendar = .current) -> DayWindow {
        let date = IntervalsDates.parseLocal(center + "T12:00:00") ?? Date()
        return DayWindow(center: calendar.date(byAdding: .day, value: 7 * weeks, to: date) ?? date, calendar: calendar)
    }
}

/// One day in the Week view: what was planned, and what was done.
public struct DayPlan: Equatable, Sendable, Identifiable {
    public let day: String
    public let sessions: [CalendarEvent]
    public let notes: [CalendarEvent]
    public let activities: [ActivitySummary]
    /// Planned sessions that an activity has been paired with in Intervals.
    public let completedEventIds: Set<Int>
    public var id: String { day }

    public var plannedLoad: Double { sessions.compactMap(\.trainingLoad).reduce(0, +) }
    public var completedLoad: Double { activities.compactMap(\.trainingLoad).reduce(0, +) }

    public func isDone(_ event: CalendarEvent) -> Bool { completedEventIds.contains(event.id) }

    /// The activity paired with this session, if it's on this day.
    public func activity(pairedWith event: CalendarEvent) -> ActivitySummary? {
        activities.first { $0.pairedEventId?.value == String(event.id) }
    }

    /// Planned sessions on this day not yet paired with an activity.
    public var unpairedSessions: [CalendarEvent] {
        sessions.filter { s in !activities.contains { $0.pairedEventId?.value == String(s.id) } }
    }

    /// Activities that don't belong to a planned session (extras, or paired elsewhere).
    public var unplannedActivities: [ActivitySummary] {
        let sessionIds = Set(sessions.map { String($0.id) })
        return activities.filter { a in a.pairedEventId.map { !sessionIds.contains($0.value) } ?? true }
    }

    /// Lays out each day in `days`. Strava stubs are left out.
    public static func build(days: [String], events: [CalendarEvent], activities: [ActivitySummary]) -> [DayPlan] {
        let real = activities.filter { !$0.isStravaPlaceholder }
        let paired = Set(real.compactMap { $0.pairedEventId.flatMap { Int($0.value) } })
        return days.map { day in
            let todays = events.filter { $0.day == day }
            return DayPlan(day: day,
                           sessions: todays.filter(\.isSession),
                           notes: todays.filter { !$0.isSession },
                           activities: real.filter { ($0.startDateLocal ?? "").hasPrefix(day) }
                               .sorted { ($0.startDateLocal ?? "") < ($1.startDateLocal ?? "") },
                           completedEventIds: paired)
        }
    }
}

public enum TodayPlan {
    /// The next planned session not yet done: today's first, else the soonest after today.
    public static func next(events: [CalendarEvent], activities: [ActivitySummary], today: String) -> CalendarEvent? {
        let done = Set(activities.compactMap { $0.pairedEventId.flatMap { Int($0.value) } })
        return events
            .filter { $0.isSession && $0.day >= today && !done.contains($0.id) }
            .min { ($0.day, $0.startDateLocal ?? "") < ($1.day, $1.startDateLocal ?? "") }
    }
}

/// A short outline of a workout's structure from its Intervals text: section headings and
/// step lines, without the prose that often sits above them.
public enum StepOutline {
    public struct Line: Equatable, Sendable {
        public let text: String
        public let isHeading: Bool
    }

    public static func lines(_ description: String?, limit: Int = 14) -> [Line] {
        guard let description else { return [] }
        let raw = description.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let firstStep = raw.firstIndex(where: { $0.hasPrefix("-") }) else { return [] }
        // The heading right above the first step belongs to the structure; prose above it doesn't.
        var start = firstStep
        if start > 0, !raw[start - 1].isEmpty { start -= 1 }

        var out: [Line] = []
        for line in raw[start...] where !line.isEmpty {
            if line.hasPrefix("-") {
                out.append(Line(text: String(line.dropFirst()).trimmingCharacters(in: .whitespaces), isHeading: false))
            } else {
                out.append(Line(text: line, isHeading: true))
            }
        }
        if out.count > limit {
            out = Array(out.prefix(limit - 1)) + [Line(text: "…", isHeading: false)]
        }
        return out
    }
}
