import SwiftUI
import RunGuideCore

/// Seven days centred on today (three either side): planned vs done per day.
/// Swipe sideways or use the arrows to move a week. Light edits only: move a session to
/// another day, delete it, or add a note. Building workouts stays on desktop/Claude.
struct WeekView: View {
    @EnvironmentObject private var calendar: CalendarStore
    @EnvironmentObject private var settings: AppSettings

    @State private var window = DayWindow(center: Date())
    @State private var moving: CalendarEvent?
    @State private var deleting: CalendarEvent?
    @State private var noteDay: String?
    @State private var noteTitle = ""
    @State private var noteText = ""

    private var today: String { IntervalsDates.day(Date()) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    totals
                }

                ForEach(plans) { plan in
                    Section {
                        dayContent(plan)
                    } header: {
                        HStack {
                            Text(WeekView.dayTitle(plan.day, today: today))
                                .foregroundStyle(plan.day == today ? Color.accentColor : .secondary)
                                .fontWeight(plan.day == today ? .bold : .regular)
                            Spacer()
                            Button {
                                noteTitle = ""
                                noteText = ""
                                noteDay = plan.day
                            } label: {
                                Image(systemName: "note.text.badge.plus")
                            }
                            .accessibilityLabel("Add a note")
                        }
                    }
                }

                if let error = calendar.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(rangeTitle)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ActivitySummary.self) { ActivityDetailView(summary: $0) }
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Previous week")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if window.center != today {
                        Button("Today") { withAnimation { window = DayWindow(center: Date()) } }
                    }
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("Next week")
                }
            }
            .overlay {
                if calendar.loading && calendar.data(for: window) == nil { ProgressView() }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        let dx = value.translation.width, dy = value.translation.height
                        guard abs(dx) > 80, abs(dx) > abs(dy) * 2 else { return }
                        shift(dx < 0 ? 1 : -1)
                    }
            )
            .refreshable { await calendar.load(window, force: true) }
            .task(id: window.first) {
                guard settings.hasCredentials else { return }
                await calendar.load(window)
            }
            .sheet(item: $moving) { event in
                MoveSheet(event: event, window: window, today: today) { day in
                    Task { await calendar.move(event, to: day, in: window) }
                }
            }
            .confirmationDialog("Delete \(deleting?.name ?? "this")?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible,
                                presenting: deleting) { event in
                Button("Delete from Intervals", role: .destructive) {
                    Task { await calendar.delete(event, in: window) }
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
                    Task { await calendar.addNote(on: day, title: title.isEmpty ? "Note" : title, text: noteText, in: window) }
                }
            } message: {
                Text(noteDay.map { WeekView.dayTitle($0, today: today) } ?? "")
            }
        }
    }

    private var data: CalendarStore.WindowData? {
        calendar.windows[window.first] ?? calendar.data(for: window)
    }

    private var plans: [DayPlan] {
        DayPlan.build(days: window.days, events: data?.events ?? [], activities: data?.activities ?? [])
    }

    private var rangeTitle: String {
        guard let a = IntervalsDates.parseLocal(window.first + "T12:00:00"),
              let b = IntervalsDates.parseLocal(window.last + "T12:00:00") else { return "Week" }
        return a.formatted(.dateTime.day().month(.abbreviated)) + " – " + b.formatted(.dateTime.day().month(.abbreviated))
    }

    private func shift(_ weeks: Int) {
        withAnimation { window = window.shifted(byWeeks: weeks) }
    }

    // MARK: - Pieces

    private var totals: some View {
        let planned = plans.map(\.plannedLoad).reduce(0, +)
        let done = plans.map(\.completedLoad).reduce(0, +)
        let time = plans.flatMap(\.activities).compactMap(\.movingTime).reduce(0, +)
        return HStack {
            figure("Planned load", "\(Int(planned.rounded()))")
            figure("Done", "\(Int(done.rounded()))")
            figure("Time", time > 0 ? Format.clock(time) : "–")
        }
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func dayContent(_ plan: DayPlan) -> some View {
        if plan.sessions.isEmpty && plan.activities.isEmpty && plan.notes.isEmpty {
            Text(plan.day < today ? "Rest" : "Nothing planned")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }

        ForEach(plan.sessions) { event in
            sessionRow(event, done: plan.isDone(event), past: plan.day < today)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { deleting = event } label: { Label("Delete", systemImage: "trash") }
                    Button { moving = event } label: { Label("Move", systemImage: "calendar") }
                        .tint(.indigo)
                }
                .contextMenu {
                    Button { moving = event } label: { Label("Move to another day", systemImage: "calendar") }
                    Button(role: .destructive) { deleting = event } label: { Label("Delete", systemImage: "trash") }
                }
        }

        ForEach(plan.activities) { activity in
            NavigationLink(value: activity) {
                ActivityRow(activity: activity)
            }
        }

        ForEach(plan.notes) { note in
            VStack(alignment: .leading, spacing: 2) {
                Label(note.name ?? "Note", systemImage: "note.text")
                    .font(.subheadline.weight(.medium))
                if let text = note.description, !text.isEmpty {
                    Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { deleting = note } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private func sessionRow(_ event: CalendarEvent, done: Bool, past: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : (past ? "xmark.circle" : "circle"))
                .foregroundStyle(done ? Color.green : (past ? Color.orange : Color.secondary))
                .accessibilityLabel(done ? "Done" : (past ? "Missed" : "Planned"))
            VStack(alignment: .leading, spacing: 2) {
                Text(event.name ?? "Session")
                    .font(.body.weight(.medium))
                    .foregroundStyle(done ? .secondary : .primary)
                Text(Self.sessionLine(event))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func sessionLine(_ e: CalendarEvent) -> String {
        var parts: [String] = []
        parts.append(e.isRace ? "Race" : (e.type ?? "Workout"))
        if let t = e.movingTime, t > 0 { parts.append(Format.clock(t)) }
        if let l = e.trainingLoad { parts.append("load \(Int(l.rounded()))") }
        return parts.joined(separator: " · ")
    }

    static func dayTitle(_ day: String, today: String) -> String {
        guard let date = IntervalsDates.parseLocal(day + "T12:00:00") else { return day }
        let cal = Calendar.current
        let name = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        if day == today { return "Today · " + name }
        if cal.isDateInYesterday(date) { return "Yesterday · " + name }
        if cal.isDateInTomorrow(date) { return "Tomorrow · " + name }
        return name
    }
}

/// Picks a new day for a session: the days around it, or any date.
struct MoveSheet: View {
    let event: CalendarEvent
    let window: DayWindow
    let today: String
    let onMove: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("Move \(event.name ?? "session") to") {
                    ForEach(window.days.filter { $0 != event.day }, id: \.self) { day in
                        Button(WeekView.dayTitle(day, today: today)) {
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
