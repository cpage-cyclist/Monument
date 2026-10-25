import SwiftUI
import RunGuideCore

// MARK: - Step editor

/// Edits one step: cue, length (time or distance), target and cadence. Shows the Intervals text
/// it will write as you go.
struct StepEditor: View {
    let sport: String
    let onDone: (PlanStep) -> Void

    @Environment(\.dismiss) private var dismiss

    private let id: UUID
    private let extra: String
    @State private var cue: String
    @State private var byDistance: Bool
    @State private var minutes: Int
    @State private var seconds: Int
    @State private var km: Double
    @State private var metric: TargetChoice
    @State private var mode: PlanTarget.Mode
    @State private var low: Double
    @State private var high: Double
    @State private var isRange: Bool
    @State private var ramp: Bool
    @State private var cadenceOn: Bool
    @State private var cadenceLow: Int
    @State private var cadenceHigh: Int
    @State private var cadenceRange: Bool

    enum TargetChoice: String, CaseIterable, Identifiable {
        case none = "None", power = "Power", heartRate = "Heart rate", lthr = "LTHR", pace = "Pace"
        var id: String { rawValue }

        var metric: PlanTarget.Metric? {
            switch self {
            case .none: nil
            case .power: .power
            case .heartRate: .heartRate
            case .lthr: .lthr
            case .pace: .pace
            }
        }

        init(_ m: PlanTarget.Metric?) {
            switch m {
            case .power: self = .power
            case .heartRate: self = .heartRate
            case .lthr: self = .lthr
            case .pace: self = .pace
            case nil: self = .none
            }
        }

        var modes: [PlanTarget.Mode] {
            switch self {
            case .none: []
            case .power: [.percent, .absolute, .zone]
            case .heartRate: [.percent, .zone]
            case .lthr: [.percent]
            case .pace: [.percent, .absolute, .zone]
            }
        }

        func label(_ mode: PlanTarget.Mode) -> String {
            switch (self, mode) {
            case (_, .zone): "Zone"
            case (.power, .percent): "% FTP"
            case (.power, .absolute): "Watts"
            case (.heartRate, _): "% max HR"
            case (.lthr, _): "% LTHR"
            case (.pace, .percent): "% threshold"
            case (.pace, .absolute): "min/km"
            default: ""
            }
        }
    }

    init(step: PlanStep, sport: String, onDone: @escaping (PlanStep) -> Void) {
        self.sport = sport
        self.onDone = onDone
        id = step.id
        extra = step.extra
        _cue = State(initialValue: step.cue)
        switch step.length {
        case .time(let s):
            _byDistance = State(initialValue: false)
            _minutes = State(initialValue: Int(s) / 60)
            _seconds = State(initialValue: Int(s) % 60)
            _km = State(initialValue: 1)
        case .distance(let d):
            _byDistance = State(initialValue: true)
            _minutes = State(initialValue: 5)
            _seconds = State(initialValue: 0)
            _km = State(initialValue: d / 1000)
        }
        let t = step.target
        _metric = State(initialValue: TargetChoice(t?.metric))
        _mode = State(initialValue: t?.mode ?? .percent)
        _low = State(initialValue: t?.low ?? 65)
        _high = State(initialValue: t?.high ?? t?.low ?? 65)
        _isRange = State(initialValue: t?.isRange ?? false)
        _ramp = State(initialValue: t?.ramp ?? false)
        _cadenceOn = State(initialValue: step.cadence != nil)
        _cadenceLow = State(initialValue: step.cadence?.low ?? 90)
        _cadenceHigh = State(initialValue: step.cadence?.high ?? step.cadence?.low ?? 95)
        _cadenceRange = State(initialValue: step.cadence?.high != nil)
    }

    private var result: PlanStep {
        var step = PlanStep(cue: cue.trimmingCharacters(in: .whitespaces),
                            length: byDistance ? .distance(max(km, 0.01) * 1000)
                                               : .time(Double(max(minutes * 60 + seconds, 1))),
                            extra: extra)
        step.id = id
        if let m = metric.metric {
            let a = low, b = isRange ? high : nil
            step.target = PlanTarget(metric: m, mode: mode, low: a, high: b, ramp: isRange && ramp)
        }
        if cadenceOn { step.cadence = CadenceRange(low: cadenceLow, high: cadenceRange ? cadenceHigh : nil) }
        return step
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Cue (optional), e.g. Seated climb or RPE 3", text: $cue)
                }

                Section("Length") {
                    Picker("Length", selection: $byDistance) {
                        Text("Time").tag(false)
                        Text("Distance").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if byDistance {
                        HStack {
                            TextField("Distance", value: $km, format: .number.precision(.fractionLength(0...3)))
                                .keyboardType(.decimalPad)
                            Text("km").foregroundStyle(.secondary)
                        }
                        quickPicks([0.2, 0.4, 0.8, 1, 2, 5], label: { $0 < 1 ? "\(Int($0 * 1000)) m" : PlanFormat.number($0) + " km" }) { km = $0 }
                    } else {
                        HStack(spacing: 0) {
                            Picker("Minutes", selection: $minutes) {
                                ForEach(0...300, id: \.self) { Text("\($0) min").tag($0) }
                            }
                            Picker("Seconds", selection: $seconds) {
                                ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text("\($0) s").tag($0) }
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(height: 120)
                    }
                }

                Section("Target") {
                    Picker("Target", selection: $metric) {
                        ForEach(TargetChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .onChange(of: metric) { _, new in
                        if !new.modes.contains(mode) { mode = new.modes.first ?? .percent }
                        resetValues()
                    }
                    if metric != .none {
                        if metric.modes.count > 1 {
                            Picker("Type", selection: $mode) {
                                ForEach(metric.modes, id: \.self) { Text(metric.label($0)).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: mode) { _, _ in resetValues() }
                        }
                        Toggle("Range", isOn: $isRange)
                        valueRow(isRange ? "From" : "Target", value: $low)
                        if isRange {
                            valueRow("To", value: $high)
                            Toggle("Ramp from one to the other", isOn: $ramp)
                        }
                    } else {
                        Text("Ride or run it by feel; the cue says what to do.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if !sport.lowercased().contains("run") && sport != "Swim" {
                    Section("Cadence") {
                        Toggle("Cadence target", isOn: $cadenceOn)
                        if cadenceOn {
                            Stepper("\(cadenceRange ? "From " : "")\(cadenceLow) rpm", value: $cadenceLow, in: 40...160, step: 5)
                            Toggle("Range", isOn: $cadenceRange)
                            if cadenceRange {
                                Stepper("To \(cadenceHigh) rpm", value: $cadenceHigh, in: 40...180, step: 5)
                            }
                        }
                    }
                }

                Section("Intervals text") {
                    Text("- " + result.text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Step")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(result)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    /// A value field fitting the target type: zones step 1–7, paces are m:ss, the rest numbers.
    @ViewBuilder
    private func valueRow(_ label: String, value: Binding<Double>) -> some View {
        switch mode {
        case .zone:
            Stepper("\(label): Z\(Int(value.wrappedValue))", value: value, in: 1...7, step: 1)
        case .absolute where metric == .pace:
            HStack {
                Text(label)
                Spacer()
                PaceField(secondsPerKm: value)
                Text("/km").foregroundStyle(.secondary)
            }
        default:
            HStack {
                Text(label)
                Spacer()
                TextField(label, value: value, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Text(mode == .absolute ? "W" : "%").foregroundStyle(.secondary)
            }
        }
    }

    /// Sensible starting values when the target type changes.
    private func resetValues() {
        switch (metric, mode) {
        case (_, .zone): low = 2; high = 3
        case (.power, .absolute): low = 200; high = 250
        case (.pace, .absolute): low = 300; high = 315
        case (.heartRate, .percent): low = 70; high = 75
        case (.lthr, _): low = 85; high = 90
        default: low = 65; high = 75
        }
    }

    private func quickPicks(_ values: [Double], label: @escaping (Double) -> String,
                            pick: @escaping (Double) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(values, id: \.self) { v in
                    Button(label(v)) { pick(v) }
                        .buttonStyle(.bordered)
                        .font(.brand(.footnote, weight: .medium))
                }
            }
        }
    }
}

/// Edits a pace as "m:ss" per km.
private struct PaceField: View {
    @Binding var secondsPerKm: Double
    @State private var text = ""

    var body: some View {
        TextField("5:00", text: $text)
            .keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(.trailing)
            .frame(width: 70)
            .onAppear { text = PlanFormat.pace(secondsPerKm) }
            .onChange(of: text) { _, new in
                let parts = new.split(separator: ":")
                if parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]), s < 60 {
                    secondsPerKm = m * 60 + s
                }
            }
            .onChange(of: secondsPerKm) { _, new in
                if PlanFormat.pace(new) != text, text.split(separator: ":").count == 2 { text = PlanFormat.pace(new) }
            }
    }
}

// MARK: - Save

/// Where to save: update the original (if it was opened from the calendar or library), add to a
/// calendar day, and/or save a copy into a library folder. Shows what Intervals made of it.
struct SaveWorkoutSheet: View {
    let origin: WorkoutLibrary.Origin
    let plan: WorkoutPlan
    let onFinished: () -> Void

    @EnvironmentObject private var library: WorkoutLibrary
    @EnvironmentObject private var calendar: CalendarStore
    @Environment(\.dismiss) private var dismiss

    @State private var updateOriginal: Bool
    @State private var addToCalendar: Bool
    @State private var day: Date
    @State private var addToLibrary: Bool
    @State private var folder: Int?
    @State private var saving = false
    @State private var error: String?
    @State private var saved: WorkoutLibrary.Saved?

    init(origin: WorkoutLibrary.Origin, plan: WorkoutPlan, scheduleDay: String? = nil,
         onFinished: @escaping () -> Void) {
        self.origin = origin
        self.plan = plan
        self.onFinished = onFinished
        if let scheduleDay {
            // Opened for a calendar day: add it there, and leave the original alone.
            _updateOriginal = State(initialValue: false)
            _addToCalendar = State(initialValue: true)
            _day = State(initialValue: IntervalsDates.parseLocal(scheduleDay + "T12:00:00") ?? Date())
            _addToLibrary = State(initialValue: false)
            if case .library(let w) = origin { _folder = State(initialValue: w.folderId) }
            return
        }
        switch origin {
        case .new(let d):
            _updateOriginal = State(initialValue: false)
            _addToCalendar = State(initialValue: d != nil)
            _day = State(initialValue: d.flatMap { IntervalsDates.parseLocal($0 + "T12:00:00") } ?? Date())
            _addToLibrary = State(initialValue: d == nil)
        case .event(let e):
            _updateOriginal = State(initialValue: true)
            _addToCalendar = State(initialValue: false)
            _day = State(initialValue: IntervalsDates.parseLocal(e.day + "T12:00:00") ?? Date())
            _addToLibrary = State(initialValue: false)
        case .library(let w):
            _updateOriginal = State(initialValue: true)
            _addToCalendar = State(initialValue: false)
            _day = State(initialValue: Date())
            _addToLibrary = State(initialValue: false)
            _folder = State(initialValue: w.folderId)
        }
    }

    private var originalLabel: String? {
        switch origin {
        case .new: nil
        case .event(let e): "Update \(DayTitle.text(e.day, today: IntervalsDates.day(Date())))'s session"
        case .library: "Update the library workout"
        }
    }

    private var choice: WorkoutLibrary.SaveChoice {
        .init(updateOriginal: updateOriginal && originalLabel != nil,
              addToDay: addToCalendar ? IntervalsDates.day(day) : nil,
              addToFolder: addToLibrary ? folder : nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let saved {
                    Section {
                        if saved.parsed {
                            Label("Saved to Intervals", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Brand.forest)
                            LabeledContent("Time", value: Format.clock(saved.time ?? 0))
                            LabeledContent("Load", value: saved.load.map { "\(Int($0.rounded()))" } ?? "–")
                        } else {
                            Label("Saved, but Intervals didn't read any steps from it. Check the text.",
                                  systemImage: "exclamationmark.triangle")
                        }
                    }
                } else {
                    if let originalLabel {
                        Section { Toggle(originalLabel, isOn: $updateOriginal) }
                    }
                    Section {
                        Toggle(originalLabel == nil ? "Add to calendar" : "Also add to calendar", isOn: $addToCalendar)
                        if addToCalendar {
                            DatePicker("Day", selection: $day, displayedComponents: .date)
                        }
                    }
                    Section {
                        Toggle(originalLabel == nil ? "Save to library" : "Also save a copy to library", isOn: $addToLibrary)
                        if addToLibrary {
                            Picker("Folder", selection: $folder) {
                                Text("Choose…").tag(Int?.none)
                                ForEach(library.saveFolders) { f in Text(f.name ?? "Folder").tag(Int?.some(f.id)) }
                            }
                        }
                    } footer: {
                        Text("Intervals works out the time and load, and syncs planned sessions to your head unit.")
                    }
                    if let error {
                        Section { Label(error, systemImage: "exclamationmark.triangle").font(.footnote) }
                    }
                }
            }
            .navigationTitle(saved == nil ? "Save workout" : plan.name.isEmpty ? "Saved" : plan.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if saved == nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        if saving {
                            ProgressView()
                        } else {
                            Button("Save") { Task { await save() } }
                                .disabled(choice.isEmpty || (addToLibrary && folder == nil))
                        }
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                            onFinished()
                        }
                    }
                }
            }
            .task { await library.load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            saved = try await library.save(plan, from: origin, choice: choice, calendar: calendar)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Library

/// The Intervals workout library by folder. Tap a workout to edit it. Opened for a calendar day,
/// a tap adds it to that day straight away (long-press to edit it first).
struct WorkoutLibraryView: View {
    var scheduleDay: String? = nil
    @EnvironmentObject private var library: WorkoutLibrary
    @EnvironmentObject private var calendar: CalendarStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var opening: WorkoutLibrary.Origin?
    @State private var adding: Int?
    @State private var addError: String?

    var body: some View {
        NavigationStack {
            List {
                if let scheduleDay {
                    Section {
                        Label("Tap a workout to add it to \(DayTitle.text(scheduleDay, today: IntervalsDates.day(Date()))). Long-press to edit it first.",
                              systemImage: "calendar.badge.plus")
                            .font(.brand(.subheadline, weight: .medium))
                        if let addError {
                            Label(addError, systemImage: "exclamationmark.triangle").font(.footnote)
                        }
                    }
                }
                ForEach(library.folders) { folder in
                    if !folder.workouts.isEmpty {
                        Section(folder.name ?? "Folder") {
                            ForEach(folder.workouts) { w in
                                Button {
                                    if let scheduleDay { Task { await add(w, to: scheduleDay) } } else { opening = .library(w) }
                                } label: { row(w) }
                                .buttonStyle(.plain)
                                .disabled(adding != nil)
                                .contextMenu {
                                    if scheduleDay != nil {
                                        Button { opening = .library(w) } label: {
                                            Label("Edit before adding", systemImage: "slider.horizontal.3")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if let error = library.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.footnote)
                }
            }
            .brandPageBackground()
            .overlay { if library.loading && library.folders.isEmpty { ProgressView() } }
            .refreshable { await library.load(force: true) }
            .navigationTitle(scheduleDay == nil ? "Library" : "Add from library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { opening = .new(day: nil) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New workout")
                }
            }
            .task {
                guard settings.hasCredentials else { return }
                await library.load()
            }
            .fullScreenCover(item: $opening) { origin in
                WorkoutBuilderView(origin: origin, scheduleDay: scheduleDay) {
                    // Added to the day: back to the Calendar.
                    if scheduleDay != nil { dismiss() }
                }
            }
        }
    }

    private func row(_ w: LibraryWorkout) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(w.name ?? "Workout").font(.brand(.body, weight: .medium))
                Text(line(w)).font(.brand(.subheadline).monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            if adding == w.id {
                ProgressView()
            } else {
                Image(systemName: scheduleDay == nil ? "chevron.right" : "plus.circle")
                    .font(scheduleDay == nil ? .caption.weight(.semibold) : .body)
                    .foregroundStyle(scheduleDay == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Brand.accent))
            }
        }
        .contentShape(Rectangle())
    }

    /// Adds a library workout to the day as it is, then goes back to the Calendar.
    private func add(_ w: LibraryWorkout, to day: String) async {
        adding = w.id
        defer { adding = nil }
        do {
            try await library.schedule(w, on: day, calendar: calendar)
            dismiss()
        } catch {
            addError = error.localizedDescription
        }
    }

    private func line(_ w: LibraryWorkout) -> String {
        var parts = [WorkoutBuilderView.sportName(w.type ?? "Ride")]
        if let t = w.movingTime, t > 0 { parts.append(Format.clock(t)) }
        if let l = w.trainingLoad { parts.append("load \(Int(l.rounded()))") }
        return parts.joined(separator: " · ")
    }
}
