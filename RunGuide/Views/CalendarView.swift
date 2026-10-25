import SwiftUI
import Charts
import RunGuideCore

/// A month at a time: fitness, fatigue and form across the month (projected ahead from planned
/// load), the month grid with each day's sessions as dots and weekly load, and the chosen day's
/// sessions underneath. Swipe sideways or use the arrows to change month. Sessions can be moved
/// or deleted, and notes added.
struct CalendarView: View {
    @EnvironmentObject private var calendar: CalendarStore
    @EnvironmentObject private var settings: AppSettings

    @State private var month = MonthGrid(containing: Date())
    @State private var selectedDay = IntervalsDates.day(Date())
    @State private var moving: CalendarEvent?
    @State private var deleting: CalendarEvent?
    @State private var noteDay: String?
    @State private var noteTitle = ""
    @State private var noteText = ""
    @State private var building: WorkoutLibrary.Origin?
    @State private var library: LibraryRequest?

    /// The library, opened from the header (no day) or for a day.
    struct LibraryRequest: Identifiable {
        let day: String?
        var id: String { day ?? "all" }
    }

    private var today: String { IntervalsDates.day(Date()) }

    var body: some View {
        NavigationStack {
            BrandScrollPage(onRefresh: refresh) {
                monthTitle
            } accessory: {
                HeaderButton(systemImage: "books.vertical", label: "Workout library") { library = LibraryRequest(day: nil) }
            } content: {
                FitnessStripCard(days: month.days,
                                 history: calendar.fitnessHistory,
                                 projected: calendar.projection(through: month.last),
                                 today: today,
                                 selectedDay: $selectedDay)

                Card { MonthGridView(month: month, plans: plans, today: today, selectedDay: $selectedDay) }

                if let plan = plans.first(where: { $0.day == selectedDay }) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SectionTitle(text: DayTitle.text(plan.day, today: today), emphasised: plan.day == today)
                            Spacer()
                            Menu {
                                Button { building = .new(day: plan.day) } label: {
                                    Label("New workout", systemImage: "plus.rectangle.on.rectangle")
                                }
                                Button { library = LibraryRequest(day: plan.day) } label: {
                                    Label("From library", systemImage: "books.vertical")
                                }
                                Button {
                                    noteTitle = ""
                                    noteText = ""
                                    noteDay = plan.day
                                } label: {
                                    Label("Add a note", systemImage: "note.text.badge.plus")
                                }
                            } label: {
                                Image(systemName: "plus.circle")
                                    .font(.system(size: 20))
                                    .frame(width: 36, height: 30)
                            }
                            .accessibilityLabel("Add to this day")
                        }
                        Card {
                            VStack(alignment: .leading, spacing: 12) {
                                DayContent(plan: plan, today: today, moving: $moving, deleting: $deleting, building: $building)
                            }
                        }
                    }
                }

                if let error = calendar.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Calendar")
            .navigationDestination(for: ActivitySummary.self) { ActivityDetailView(summary: $0) }
            .overlay {
                if calendar.loading && calendar.data(for: month) == nil { ProgressView() }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        let dx = value.translation.width, dy = value.translation.height
                        guard abs(dx) > 80, abs(dx) > abs(dy) * 2 else { return }
                        shift(dx < 0 ? 1 : -1)
                    }
            )
            .task(id: month.first) {
                guard settings.hasCredentials else { return }
                async let m: Void = calendar.load(month)
                async let a: Void = calendar.loadAhead(through: month.last)
                async let f: Void = calendar.refreshToday()
                _ = await (m, a, f)
            }
            .fullScreenCover(item: $building) { WorkoutBuilderView(origin: $0) }
            .sheet(item: $library) { WorkoutLibraryView(scheduleDay: $0.day) }
            .onChange(of: calendar.revision) { _, _ in Task { await refresh() } }
            .sheet(item: $moving) { event in
                MoveSheet(event: event, days: week(containing: event.day), today: today) { day in
                    Task { await calendar.move(event, to: day, in: month) }
                }
            }
            .confirmationDialog("Delete \(deleting?.name ?? "this")?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible,
                                presenting: deleting) { event in
                Button("Delete from Intervals", role: .destructive) {
                    Task { await calendar.delete(event, in: month) }
                }
            } message: { _ in
                Text("It's removed from your Intervals calendar and any synced head unit.")
            }
            .alert("Add a note", isPresented: Binding(get: { noteDay != nil }, set: { if !$0 { noteDay = nil } })) {
                TextField("Title", text: $noteTitle)
                TextField("Note (optional)", text: $noteText)
                Button("Cancel", role: .cancel) {}
                Button("Add") {
                    guard let day = noteDay else { return }
                    let title = noteTitle.trimmingCharacters(in: .whitespaces)
                    Task { await calendar.addNote(on: day, title: title.isEmpty ? "Note" : title, text: noteText, in: month) }
                }
            } message: {
                Text(noteDay.map { DayTitle.text($0, today: today) } ?? "")
            }
        }
    }

    private var data: CalendarStore.WindowData? {
        calendar.windows[month.first] ?? calendar.data(for: month)
    }

    private var plans: [DayPlan] {
        DayPlan.build(days: month.days, events: data?.events ?? [], activities: data?.activities ?? [])
    }

    private func refresh() async {
        async let m: Void = calendar.load(month, force: true)
        async let a: Void = calendar.loadAhead(through: month.last, force: true)
        async let f: Void = calendar.refreshToday(force: true)
        _ = await (m, a, f)
    }

    private func shift(_ months: Int) {
        withAnimation {
            month = month.shifted(byMonths: months)
            selectedDay = month.contains(today) ? today : month.prefix + "-01"
        }
    }

    private func goToToday() {
        withAnimation {
            month = MonthGrid(containing: Date())
            selectedDay = today
        }
    }

    /// The Monday-to-Sunday week around a day, for the move sheet's quick picks.
    private func week(containing day: String) -> [String] {
        month.weeks.first { $0.contains(day) }
            ?? MonthGrid(containing: IntervalsDates.parseLocal(day + "T12:00:00") ?? Date()).weeks.first { $0.contains(day) }
            ?? [day]
    }

    /// "Calendar", then the month with arrows (and back to today).
    private var monthTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            PageTitle(text: "Calendar")
            HStack(spacing: 0) {
                Text(month.firstOfMonth.formatted(.dateTime.month(.wide).year()))
                    .font(.brand(.title3, weight: .medium))
                Spacer()
                if !month.contains(today) || selectedDay != today {
                    Button("Today", action: goToToday)
                        .font(.brand(.subheadline, weight: .medium))
                        .padding(.trailing, 6)
                }
                Button { shift(-1) } label: {
                    Image(systemName: "chevron.left").frame(width: 40, height: 40)
                }
                .accessibilityLabel("Previous month")
                Button { shift(1) } label: {
                    Image(systemName: "chevron.right").frame(width: 40, height: 40)
                }
                .accessibilityLabel("Next month")
            }
        }
    }
}

// MARK: - Month grid

/// Monday-first weeks: each day shows its date and a dot per session or activity, and each row
/// ends with the week's load done (and planned underneath).
struct MonthGridView: View {
    let month: MonthGrid
    let plans: [DayPlan]
    let today: String
    @Binding var selectedDay: String

    private static let weekdays = ["M", "T", "W", "T", "F", "S", "S"]
    private static let loadWidth: CGFloat = 40

    var body: some View {
        let byDay = Dictionary(uniqueKeysWithValues: plans.map { ($0.day, $0) })
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(Array(Self.weekdays.enumerated()), id: \.offset) { _, d in
                    Text(d).font(.brand(.caption2, weight: .medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                Text("Load").font(.brand(.caption2, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: Self.loadWidth, alignment: .trailing)
            }
            ForEach(month.weeks, id: \.self) { week in
                Hairline()
                HStack(spacing: 0) {
                    ForEach(week, id: \.self) { day in
                        DayCell(day: day, plan: byDay[day], inMonth: month.contains(day), today: today,
                                selected: day == selectedDay)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedDay = day }
                    }
                    weekLoad(week.compactMap { byDay[$0] })
                        .frame(width: Self.loadWidth, alignment: .trailing)
                }
            }
        }
    }

    private func weekLoad(_ days: [DayPlan]) -> some View {
        let done = days.map(\.completedLoad).reduce(0, +)
        let planned = days.map(\.plannedLoad).reduce(0, +)
        return VStack(alignment: .trailing, spacing: 1) {
            Text(done > 0 ? "\(Int(done.rounded()))" : "–")
                .font(.brand(.footnote, weight: .bold).monospacedDigit())
            if planned > 0 {
                Text("\(Int(planned.rounded()))")
                    .font(.brand(.caption2).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Week load \(Int(done.rounded())) done, \(Int(planned.rounded())) planned")
    }
}

/// One day in the grid.
private struct DayCell: View {
    let day: String
    let plan: DayPlan?
    let inMonth: Bool
    let today: String
    let selected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(String(Int(day.suffix(2)) ?? 0))
                .font(.brand(.subheadline, weight: day == today || selected ? .bold : .regular).monospacedDigit())
                .foregroundStyle(selected ? Color.white : (inMonth ? Color.primary : Color.secondary.opacity(0.6)))
                .frame(width: 30, height: 30)
                .background {
                    if selected {
                        Circle().fill(Brand.forest)
                    } else if day == today {
                        Circle().strokeBorder(Brand.forest, lineWidth: 1.5)
                    }
                }
            HStack(spacing: 3) {
                ForEach(Array(dots.prefix(3).enumerated()), id: \.offset) { _, dot in
                    dot.view
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 4)
        .opacity(inMonth ? 1 : 0.55)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DayTitle.text(day, today: today) + accessibilitySummary)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private enum Dot {
        case done, planned, missed, race, extra

        @ViewBuilder var view: some View {
            switch self {
            case .done: Circle().fill(Brand.forest).frame(width: 6, height: 6)
            case .planned: Circle().strokeBorder(Brand.forest, lineWidth: 1.2).frame(width: 6, height: 6)
            case .missed: Circle().fill(Brand.Medal.bronze.flat).frame(width: 6, height: 6)
            case .race: Circle().fill(Brand.Medal.gold.flat).frame(width: 6, height: 6)
            case .extra: Circle().fill(Brand.sage).frame(width: 6, height: 6)
            }
        }
    }

    private var dots: [Dot] {
        guard let plan else { return [] }
        let sessions: [Dot] = plan.sessions.map { e in
            if plan.isDone(e) { return .done }
            if e.isRace { return .race }
            return day < today ? .missed : .planned
        }
        return sessions + plan.unplannedActivities.map { _ in .extra }
    }

    private var accessibilitySummary: String {
        guard let plan, !(plan.sessions.isEmpty && plan.activities.isEmpty) else { return "" }
        var parts: [String] = []
        if !plan.sessions.isEmpty { parts.append("\(plan.sessions.count) planned") }
        if !plan.activities.isEmpty { parts.append("\(plan.activities.count) done") }
        return ", " + parts.joined(separator: ", ")
    }
}

// MARK: - Fitness strip

/// Fitness and fatigue across the month's dates, form underneath. Known days are solid; days
/// projected from planned load are dashed. Drag across it, or pick a day in the grid, to read
/// that day's numbers.
struct FitnessStripCard: View {
    let days: [String]
    let history: [WellnessDay]
    let projected: [WellnessDay]
    let today: String
    @Binding var selectedDay: String

    @State private var scrubDate: Date?

    private struct Point: Identifiable {
        let date: Date
        let day: WellnessDay
        let projected: Bool
        var id: String { day.id }
    }

    private var points: [Point] {
        guard let first = days.first, let last = days.last else { return [] }
        let projectedById = Dictionary(uniqueKeysWithValues: projected.map { ($0.id, $0) })
        let known = history.filter { $0.id >= first && $0.id <= last && $0.ctl != nil && $0.atl != nil
            && projectedById[$0.id] == nil }
        let all = known.map { ($0, false) } + projected.filter { $0.id >= first && $0.id <= last }.map { ($0, true) }
        return all.compactMap { d, p in
            IntervalsDates.parseLocal(d.id + "T12:00:00").map { Point(date: $0, day: d, projected: p) }
        }
        .sorted { $0.id < $1.id }
    }

    /// Known days, then projected days starting from the last known one so the lines join up.
    private var segments: (known: [Point], ahead: [Point]) {
        let all = points
        let known = all.filter { !$0.projected }
        var ahead = all.filter(\.projected)
        if let join = known.last, !ahead.isEmpty { ahead.insert(join, at: 0) }
        return (known, ahead)
    }

    private var domainDates: ClosedRange<Date> {
        let a = days.first.flatMap { IntervalsDates.parseLocal($0 + "T00:00:00") } ?? Date()
        let b = days.last.flatMap { IntervalsDates.parseLocal($0 + "T23:59:59") } ?? Date()
        return a...b
    }

    private var selected: Point? { points.first { $0.id == selectedDay } }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    key("Fitness", Brand.forest, selected?.day.ctl)
                    key("Fatigue", .white, selected?.day.atl)
                    key("Form", Brand.forest, selected?.day.form, signed: true)
                    Spacer(minLength: 0)
                    if selected?.projected == true {
                        Text("Projected").font(.brand(.caption, weight: .medium)).foregroundStyle(.secondary)
                    } else if let zone = selected?.day.formZone {
                        Text(zone.rawValue).font(.brand(.caption)).foregroundStyle(.secondary)
                    }
                }

                if points.count < 2 {
                    Text("No fitness numbers for this month.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    loadChart
                    formChart
                }
            }
        }
        .onChange(of: scrubDate) { _, date in
            guard let date else { return }
            if let nearest = points.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }) {
                selectedDay = nearest.id
            }
        }
    }

    private func key(_ label: String, _ color: Color, _ value: Double?, signed: Bool = false) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption).foregroundStyle(.secondary)
            if let value {
                let v = Int(value.rounded())
                Text(signed && v > 0 ? "+\(v)" : "\(v)").font(.caption.monospacedDigit().weight(.semibold))
            }
        }
    }

    private static let dashed = StrokeStyle(lineWidth: 1.5, dash: [4, 3])

    private var loadChart: some View {
        let (known, ahead) = segments
        return Chart {
            ForEach(known) { p in
                LineMark(x: .value("Day", p.date), y: .value("Load", p.day.ctl ?? 0), series: .value("Series", "Fitness"))
                    .foregroundStyle(Brand.forest).lineStyle(StrokeStyle(lineWidth: 2.5))
                LineMark(x: .value("Day", p.date), y: .value("Load", p.day.atl ?? 0), series: .value("Series", "Fatigue"))
                    .foregroundStyle(.white).lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            ForEach(ahead) { p in
                LineMark(x: .value("Day", p.date), y: .value("Load", p.day.ctl ?? 0), series: .value("Series", "Fitness ahead"))
                    .foregroundStyle(Brand.forest).lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                LineMark(x: .value("Day", p.date), y: .value("Load", p.day.atl ?? 0), series: .value("Series", "Fatigue ahead"))
                    .foregroundStyle(.white).lineStyle(Self.dashed)
            }
            markers
        }
        .chartXScale(domain: domainDates)
        .chartYScale(domain: loadDomain)
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
        .chartXSelection(value: $scrubDate)
        .frame(height: 96)
    }

    private var formChart: some View {
        let (known, ahead) = segments
        return Chart {
            RectangleMark(yStart: .value("Form", -30), yEnd: .value("Form", -10))
                .foregroundStyle(Color.white.opacity(0.4))
            RuleMark(y: .value("Form", 0)).foregroundStyle(Brand.forest.opacity(0.6))
            ForEach(known) { p in
                LineMark(x: .value("Day", p.date), y: .value("Form", p.day.form ?? 0), series: .value("Series", "Form"))
                    .foregroundStyle(Brand.forest).lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            ForEach(ahead) { p in
                LineMark(x: .value("Day", p.date), y: .value("Form", p.day.form ?? 0), series: .value("Series", "Form ahead"))
                    .foregroundStyle(Brand.forest).lineStyle(Self.dashed)
            }
            markers
        }
        .chartXScale(domain: domainDates)
        .chartYScale(domain: formDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
        .chartXSelection(value: $scrubDate)
        .frame(height: 70)
    }

    /// Today, and the chosen day.
    @ChartContentBuilder private var markers: some ChartContent {
        if let t = IntervalsDates.parseLocal(today + "T12:00:00"), domainDates.contains(t) {
            RuleMark(x: .value("Day", t)).foregroundStyle(Brand.forest.opacity(0.25))
        }
        if let s = IntervalsDates.parseLocal(selectedDay + "T12:00:00"), domainDates.contains(s) {
            RuleMark(x: .value("Day", s)).foregroundStyle(Color.primary.opacity(0.45))
        }
    }

    private var loadDomain: ClosedRange<Double> {
        let values = points.flatMap { [$0.day.ctl, $0.day.atl].compactMap { $0 } }
        guard let lo = values.min(), let hi = values.max() else { return 0...100 }
        let span = max(hi - lo, 10)
        return max(lo - span * 0.1, 0)...(hi + span * 0.1)
    }

    private var formDomain: ClosedRange<Double> {
        let values = points.compactMap(\.day.form)
        let lo = min(values.min() ?? -30, -30), hi = max(values.max() ?? 10, 10)
        let span = hi - lo
        return (lo - span * 0.08)...(hi + span * 0.08)
    }
}

// MARK: - Day

/// A day's planned sessions, activities and notes. Tap a planned workout to edit it; its context
/// menu also moves or deletes it. Activities open their detail.
struct DayContent: View {
    let plan: DayPlan
    let today: String
    @Binding var moving: CalendarEvent?
    @Binding var deleting: CalendarEvent?
    @Binding var building: WorkoutLibrary.Origin?

    var body: some View {
        if plan.sessions.isEmpty && plan.activities.isEmpty && plan.notes.isEmpty {
            Text(plan.day < today ? "Rest" : "Nothing planned")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }

        ForEach(plan.sessions) { event in
            sessionRow(event, done: plan.isDone(event), past: plan.day < today)
                .contentShape(Rectangle())
                .contentShape(Rectangle())
                .onTapGesture { if event.isWorkout { building = .event(event) } }
                .contextMenu {
                    if event.isWorkout {
                        Button { building = .event(event) } label: { Label("Edit workout", systemImage: "slider.horizontal.3") }
                    }
                    Button { moving = event } label: { Label("Move to another day", systemImage: "calendar") }
                    Button(role: .destructive) { deleting = event } label: { Label("Delete", systemImage: "trash") }
                }
        }

        ForEach(plan.activities) { activity in
            NavigationLink(value: activity) {
                HStack {
                    ActivityRow(activity: activity)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }

        ForEach(plan.notes) { note in
            VStack(alignment: .leading, spacing: 2) {
                Label(note.name ?? "Note", systemImage: "note.text")
                    .font(.subheadline.weight(.medium))
                if let text = note.description, !text.isEmpty {
                    Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button(role: .destructive) { deleting = note } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private func sessionRow(_ event: CalendarEvent, done: Bool, past: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : (past ? "xmark.circle" : "circle"))
                .foregroundStyle(done ? Brand.forest : (past ? Brand.Medal.bronze.flat : Color.secondary))
                .accessibilityLabel(done ? "Done" : (past ? "Missed" : "Planned"))
            VStack(alignment: .leading, spacing: 2) {
                Text(event.name ?? "Session")
                    .font(.body.weight(.medium))
                    .foregroundStyle(done ? .secondary : .primary)
                Text(DayTitle.sessionLine(event))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Day and session labels shared by Today and the Calendar.
enum DayTitle {
    static func text(_ day: String, today: String) -> String {
        guard let date = IntervalsDates.parseLocal(day + "T12:00:00") else { return day }
        let cal = Calendar.current
        let name = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        if day == today { return "Today · " + name }
        if cal.isDateInYesterday(date) { return "Yesterday · " + name }
        if cal.isDateInTomorrow(date) { return "Tomorrow · " + name }
        return name
    }

    static func sessionLine(_ e: CalendarEvent) -> String {
        var parts: [String] = []
        parts.append(e.isRace ? "Race" : (e.type ?? "Workout"))
        if let t = e.movingTime, t > 0 { parts.append(Format.clock(t)) }
        if let l = e.trainingLoad { parts.append("load \(Int(l.rounded()))") }
        return parts.joined(separator: " · ")
    }
}

/// Picks a new day for a session: the rest of its week, or any date.
struct MoveSheet: View {
    let event: CalendarEvent
    let days: [String]
    let today: String
    let onMove: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("Move \(event.name ?? "session") to") {
                    ForEach(days.filter { $0 != event.day }, id: \.self) { day in
                        Button(DayTitle.text(day, today: today)) {
                            onMove(day)
                            dismiss()
                        }
                    }
                }
                Section("Another day") {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Button("Move to \(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))") {
                        onMove(IntervalsDates.day(date))
                        dismiss()
                    }
                }
            }
            .navigationTitle("Move")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear {
                date = IntervalsDates.parseLocal(event.day + "T12:00:00") ?? Date()
            }
        }
        .presentationDetents([.medium, .large])
    }
}
