import Foundation

// The Calendar tab: a Monday-first month grid, and fitness projected forward from planned load.

extension IntervalsDates {
    /// "2026-10-25" moved by `days` (negative goes back). Worked at midday so clock changes can't
    /// slip a day.
    public static func adding(_ days: Int, to day: String, calendar: Calendar = .current) -> String {
        guard let date = parseLocal(day + "T12:00:00"),
              let moved = calendar.date(byAdding: .day, value: days, to: date) else { return day }
        return self.day(moved)
    }

    /// Every day from `first` to `last`, inclusive.
    public static func days(from first: String, through last: String, calendar: Calendar = .current) -> [String] {
        guard first <= last else { return [] }
        var out: [String] = []
        var d = first
        while d <= last, out.count < 1000 {
            out.append(d)
            d = adding(1, to: d, calendar: calendar)
        }
        return out
    }
}

/// One month laid out in whole Monday-to-Sunday weeks, with the neighbouring months' days
/// filling the first and last rows.
public struct MonthGrid: Equatable, Hashable, Sendable {
    public let year: Int
    public let month: Int
    /// Four to six rows of seven days, "2026-10-26" style.
    public let weeks: [[String]]

    public init(containing date: Date, calendar: Calendar = .current) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = calendar.timeZone
        let parts = cal.dateComponents([.year, .month], from: date)
        year = parts.year ?? 2026
        month = parts.month ?? 1

        let first = cal.date(from: DateComponents(year: year, month: month, day: 1, hour: 12)) ?? date
        let length = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        // Calendar weekdays run Sunday = 1 … Saturday = 7; Monday-first offset is 0 … 6.
        let lead = (cal.component(.weekday, from: first) + 5) % 7
        let cells = Int((Double(lead + length) / 7).rounded(.up)) * 7
        let start = cal.date(byAdding: .day, value: -lead, to: first) ?? first
        let days = (0..<cells).compactMap { cal.date(byAdding: .day, value: $0, to: start).map(IntervalsDates.day) }
        weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
    }

    public var days: [String] { weeks.flatMap { $0 } }
    public var first: String { weeks.first?.first ?? "" }
    public var last: String { weeks.last?.last ?? "" }
    /// "2026-10".
    public var prefix: String { String(format: "%04d-%02d", year, month) }
    public func contains(_ day: String) -> Bool { day.hasPrefix(prefix) }

    /// Midday on the 1st, for formatting the title.
    public var firstOfMonth: Date {
        IntervalsDates.parseLocal(prefix + "-01T12:00:00") ?? Date()
    }

    public func shifted(byMonths months: Int, calendar: Calendar = .current) -> MonthGrid {
        let moved = calendar.date(byAdding: .month, value: months, to: firstOfMonth) ?? firstOfMonth
        return MonthGrid(containing: moved, calendar: calendar)
    }
}

/// Fitness (CTL), fatigue (ATL) and form carried forward day by day from the last known values,
/// using planned load for days still to come. Same exponentially weighted averages as Intervals:
/// fitness over 42 days, fatigue over 7.
public enum FitnessProjection {
    public static let fitnessDays = 42.0
    public static let fatigueDays = 7.0

    /// One day's update of an exponentially weighted average.
    public static func step(_ value: Double, load: Double, days: Double) -> Double {
        value + (load - value) * (1 - exp(-1 / days))
    }

    /// Planned load per day from `today` on, for sessions not yet done.
    public static func plannedLoads(events: [CalendarEvent], activities: [ActivitySummary],
                                    from today: String) -> [String: Double] {
        let done = Set(activities.compactMap { $0.pairedEventId.flatMap { Int($0.value) } })
        var out: [String: Double] = [:]
        for e in events where e.isSession && e.day >= today && !done.contains(e.id) {
            out[e.day, default: 0] += e.trainingLoad ?? 0
        }
        return out
    }

    /// Load already done per day (Strava stubs left out).
    public static func completedLoads(_ activities: [ActivitySummary]) -> [String: Double] {
        var out: [String: Double] = [:]
        for a in activities where !a.isStravaPlaceholder {
            out[String((a.startDateLocal ?? "").prefix(10)), default: 0] += a.trainingLoad ?? 0
        }
        return out
    }

    /// Projected days after the last known one, through `end`.
    ///
    /// Intervals' figure for today only counts what's been done so far, so when a session is still
    /// planned for today, today is worked out again from yesterday with that session included.
    /// Days between the last known day and today (if any) use completed load.
    public static func project(history: [WellnessDay], planned: [String: Double], completed: [String: Double],
                               today: String, through end: String, calendar: Calendar = .current) -> [WellnessDay] {
        let known = history.filter { $0.id <= today && $0.ctl != nil && $0.atl != nil }.sorted { $0.id < $1.id }
        guard var base = known.last else { return [] }
        if base.id == today, (planned[today] ?? 0) > 0, let previous = known.dropLast().last {
            base = previous
        }
        guard var ctl = base.ctl, var atl = base.atl else { return [] }

        let start = IntervalsDates.adding(1, to: base.id, calendar: calendar)
        return IntervalsDates.days(from: start, through: end, calendar: calendar).map { day in
            let load: Double
            if day < today {
                load = completed[day] ?? 0
            } else if day == today {
                load = (completed[day] ?? 0) + (planned[day] ?? 0)
            } else {
                load = planned[day] ?? 0
            }
            ctl = step(ctl, load: load, days: fitnessDays)
            atl = step(atl, load: load, days: fatigueDays)
            return WellnessDay(id: day, ctl: ctl, atl: atl)
        }
    }
}
