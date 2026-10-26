import SwiftUI
import RunGuideCore

/// Builds or edits a workout: name and sport, the structure chart, then blocks of steps (a block
/// can repeat). Tap a step to edit it, or a bar in the chart to jump to its step. "Edit as text"
/// shows the Intervals workout text directly. Saving goes to a calendar day and/or the library.
struct WorkoutBuilderView: View {
    let origin: WorkoutLibrary.Origin
    /// The calendar day it was opened for, if any: saving then defaults to adding it there.
    let scheduleDay: String?
    /// Called after a successful save, once the builder has closed.
    let onSaved: () -> Void

    @EnvironmentObject private var library: WorkoutLibrary
    @EnvironmentObject private var activities: ActivityLibrary
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var rider: RiderStore
    @Environment(\.dismiss) private var dismiss

    @State private var plan: WorkoutPlan
    @State private var original: WorkoutPlan
    @State private var editing: StepRef?
    @State private var selectedStep: UUID?
    @State private var textMode = false
    @State private var draft = ""
    @State private var saving = false
    @State private var confirmDiscard = false

    struct StepRef: Identifiable, Hashable {
        let block: UUID
        let step: UUID
        var id: UUID { step }
    }

    init(origin: WorkoutLibrary.Origin, scheduleDay: String? = nil, onSaved: @escaping () -> Void = {}) {
        self.origin = origin
        self.scheduleDay = scheduleDay
        self.onSaved = onSaved
        let start: WorkoutPlan
        switch origin {
        case .new: start = WorkoutPlan(name: "", sport: "Ride", blocks: WorkoutBuilderView.starter(sport: "Ride"))
        case .event(let e): start = WorkoutPlan(event: e)
        case .library(let w): start = WorkoutPlan(library: w)
        }
        _plan = State(initialValue: start)
        _original = State(initialValue: start)
    }

    private var context: PlanContext {
        PlanContext(ftp: rider.ftp(settings.thresholdSource, intervalsFallback: activities.latestFTP))
    }

    private var isNew: Bool { if case .new = origin { true } else { false } }

    var body: some View {
        NavigationStack {
            Group {
                if textMode { textEditor } else { blockEditor }
            }
                        .ridgeSheetHeader(scheduleDay != nil ? "Add" : (isNew ? "New" : "Edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if currentPlan != original { confirmDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saving = true }
                        .disabled(currentPlan.blocks.isEmpty && currentPlan.notes.isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        Button(textMode ? "Edit as blocks" : "Edit as text") { toggleText() }
                        Spacer()
                        if !textMode { EditButton() }
                    }
                }
            }
            .confirmationDialog("Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
            }
            .sheet(item: $editing) { ref in
                if let step = plan.step(ref.step) {
                    StepEditor(step: step, sport: plan.sport) { updated in replace(ref, with: updated) }
                }
            }
            .sheet(isPresented: $saving) {
                SaveWorkoutSheet(origin: origin, plan: currentPlan, scheduleDay: scheduleDay) {
                    dismiss()
                    onSaved()
                }
            }
            .task { await loadFullTextIfNeeded() }
        }
    }

    /// The plan as it stands, including unapplied text edits.
    private var currentPlan: WorkoutPlan {
        guard textMode else { return plan }
        return WorkoutPlan(text: draft, name: plan.name, sport: plan.sport, indoor: plan.indoor)
    }

    // MARK: - Block editor

    private static let sports = ["Ride", "VirtualRide", "Run", "Swim", "Workout"]

    private var blockEditor: some View {
        BrandList {
            Section {
                TextField("Name", text: $plan.name)
                    .font(.brand(.headline, weight: .medium))
                Picker("Sport", selection: $plan.sport) {
                    ForEach(Self.sports + (Self.sports.contains(plan.sport) ? [] : [plan.sport]), id: \.self) {
                        Text(Self.sportName($0)).tag($0)
                    }
                }
                Toggle("Indoor", isOn: $plan.indoor)
            }

            Section {
                let segments = plan.segments(context)
                if segments.isEmpty {
                    Text("Add steps to see the workout's shape.")
                        .font(.brand(.footnote)).foregroundStyle(.secondary)
                } else {
                    StructureChart(segments: segments, selected: selectedStep) { id in
                        selectedStep = id
                        if let block = plan.blocks.first(where: { $0.steps.contains { $0.id == id } }) {
                            editing = StepRef(block: block.id, step: id)
                        }
                    }
                    .frame(height: 130)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 8, trailing: 12))
                    summary
                }
            }

            ForEach($plan.blocks) { $block in
                Section {
                    ForEach(block.steps) { step in
                        Button {
                            selectedStep = step.id
                            editing = StepRef(block: block.id, step: step.id)
                        } label: {
                            StepRow(step: step, selected: step.id == selectedStep)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { block.steps.remove(atOffsets: $0) }
                    .onMove { block.steps.move(fromOffsets: $0, toOffset: $1) }

                    Button {
                        let step = Self.defaultStep(sport: plan.sport, after: block.steps.last)
                        block.steps.append(step)
                        editing = StepRef(block: block.id, step: step.id)
                    } label: {
                        Label("Add step", systemImage: "plus")
                    }
                } header: {
                    BlockHeader(block: $block,
                                onMove: { moveBlock(block.id, by: $0) },
                                onDuplicate: { duplicateBlock(block.id) },
                                onDelete: { plan.blocks.removeAll { $0.id == block.id } })
                }
            }

            Section {
                Button {
                    plan.blocks.append(PlanBlock(steps: [Self.defaultStep(sport: plan.sport, after: nil)]))
                } label: {
                    Label("Add steps", systemImage: "plus.rectangle")
                }
                Button {
                    plan.blocks.append(Self.repeatSet(sport: plan.sport))
                } label: {
                    Label("Add repeat set", systemImage: "repeat")
                }
            }

            BrandSection("Notes") {
                TextEditor(text: $plan.notes)
                    .frame(minHeight: 70)
                    .font(.brand(.subheadline))
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var summary: some View {
        let seconds = plan.totalSeconds(context)
        let load = plan.estimatedLoad(context)
        let steps = plan.blocks.reduce(0) { $0 + $1.steps.count * $1.repeats }
        return HStack(spacing: 18) {
            figure("Time", Format.clock(seconds))
            figure("Load", "≈ \(Int(load.rounded()))")
            figure("Steps", "\(steps)")
        }
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.brand(.caption)).foregroundStyle(.secondary)
            Text(value).font(.num(.headline, weight: .bold))
        }
    }

    // MARK: - Text editor

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Intervals workout text. Steps start with \"- \"; a line ending in 3x repeats the steps under it until a blank line; m is minutes, mtr is metres.")
                .font(.brand(.footnote))
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            TextEditor(text: $draft)
                .font(.num(.body))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Brand.sky)
                .overlay { Rectangle().strokeBorder(Brand.hairline, lineWidth: 1) }
                .padding(.horizontal)
        }
        .padding(.top, 8)
    }

    private func toggleText() {
        if textMode {
            plan = currentPlan
            textMode = false
        } else {
            draft = plan.text
            textMode = true
        }
    }

    // MARK: - Edits

    private func replace(_ ref: StepRef, with step: PlanStep) {
        guard let b = plan.blocks.firstIndex(where: { $0.id == ref.block }),
              let s = plan.blocks[b].steps.firstIndex(where: { $0.id == ref.step }) else { return }
        plan.blocks[b].steps[s] = step
    }

    private func moveBlock(_ id: UUID, by offset: Int) {
        guard let i = plan.blocks.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard plan.blocks.indices.contains(j) else { return }
        plan.blocks.swapAt(i, j)
    }

    private func duplicateBlock(_ id: UUID) {
        guard let i = plan.blocks.firstIndex(where: { $0.id == id }) else { return }
        var copy = plan.blocks[i]
        copy.id = UUID()
        copy.steps = copy.steps.map { var s = $0; s.id = UUID(); return s }
        plan.blocks.insert(copy, at: i + 1)
    }

    /// Library workouts listed in folders may come without their step text; fetch it if so.
    private func loadFullTextIfNeeded() async {
        guard case .library(let w) = origin, (w.description ?? "").isEmpty, settings.hasCredentials,
              let full = try? await AppSettings.currentClient().libraryWorkout(id: w.id),
              !(full.description ?? "").isEmpty else { return }
        let loaded = WorkoutPlan(library: full)
        if plan == original { plan = loaded }
        original = loaded
    }

    // MARK: - Defaults

    static func sportName(_ s: String) -> String {
        switch s {
        case "VirtualRide": "Indoor ride"
        case "Workout": "Other"
        default: s
        }
    }

    static func defaultStep(sport: String, after previous: PlanStep?) -> PlanStep {
        if var p = previous { p.id = UUID(); return p }
        if sport.lowercased().contains("run") {
            return PlanStep(length: .time(600), target: PlanTarget(metric: .pace, mode: .zone, low: 2))
        }
        return PlanStep(length: .time(600), target: PlanTarget(metric: .power, mode: .percent, low: 65))
    }

    static func repeatSet(sport: String) -> PlanBlock {
        if sport.lowercased().contains("run") {
            return PlanBlock(title: "Main set", repeats: 5, steps: [
                PlanStep(length: .distance(1000), target: PlanTarget(metric: .pace, mode: .percent, low: 100, high: 103)),
                PlanStep(cue: "Float", length: .time(90), target: PlanTarget(metric: .pace, mode: .zone, low: 1))
            ])
        }
        return PlanBlock(title: "Main set", repeats: 3, steps: [
            PlanStep(length: .time(480), target: PlanTarget(metric: .power, mode: .percent, low: 95, high: 100)),
            PlanStep(length: .time(240), target: PlanTarget(metric: .power, mode: .percent, low: 55))
        ])
    }

    static func starter(sport: String) -> [PlanBlock] {
        [PlanBlock(title: "Warmup", steps: [PlanStep(length: .time(900), target:
            PlanTarget(metric: .power, mode: .percent, low: 50, high: 75, ramp: true))]),
         repeatSet(sport: sport),
         PlanBlock(title: "Cooldown", steps: [PlanStep(length: .time(600), target:
            PlanTarget(metric: .power, mode: .percent, low: 50))])]
    }
}

// MARK: - Pieces

/// A block's name, repeat count and actions, above its steps.
private struct BlockHeader: View {
    @Binding var block: PlanBlock
    let onMove: (Int) -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField(block.repeats > 1 ? "Repeat set" : "Block name", text: $block.title)
                .font(.brand(.subheadline, weight: .bold))
            Stepper(value: $block.repeats, in: 1...50) {
                Text(block.repeats > 1 ? "\(block.repeats)×" : "Once")
                    .font(.num(.subheadline, weight: .medium))
            }
            .fixedSize()
            Menu {
                Button { onMove(-1) } label: { Label("Move up", systemImage: "arrow.up") }
                Button { onMove(1) } label: { Label("Move down", systemImage: "arrow.down") }
                Button(action: onDuplicate) { Label("Duplicate", systemImage: "plus.square.on.square") }
                Button(role: .destructive, action: onDelete) { Label("Delete block", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 30, height: 30)
            }
            .accessibilityLabel("Block actions")
        }
        .textCase(nil)
        .foregroundStyle(.primary)
    }
}

/// One step: its cue (or length), and length · target · cadence.
private struct StepRow: View {
    let step: PlanStep
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(selected ? Brand.Medal.gold.flat : Brand.forest.opacity(step.target == nil ? 0.25 : 0.8))
                .frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.cue.isEmpty ? StepText.length(step.length) : step.cue)
                    .font(.brand(.body, weight: .medium))
                Text(StepText.detail(step, includeLength: !step.cue.isEmpty))
                    .font(.num(.subheadline))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.brand(.caption, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// Plain-English labels for lengths and targets.
enum StepText {
    static func length(_ l: PlanLength) -> String {
        switch l {
        case .time(let s):
            if s <= 0 { return "Open" }
            let h = Int(s) / 3600, m = (Int(s) % 3600) / 60, sec = Int(s) % 60
            var parts: [String] = []
            if h > 0 { parts.append("\(h) h") }
            if m > 0 { parts.append("\(m) min") }
            if sec > 0 { parts.append("\(sec) s") }
            return parts.joined(separator: " ")
        case .distance(let d):
            return d >= 1000 ? PlanFormat.number((d / 10).rounded() / 100) + " km" : "\(Int(d)) m"
        }
    }

    static func target(_ t: PlanTarget) -> String {
        let ramp = t.ramp ? "Ramp " : ""
        let r: (String) -> String = { unit in
            let f: (Double) -> String = t.mode == .absolute && t.metric == .pace ? PlanFormat.pace : PlanFormat.number
            let lo = f(t.low)
            return (t.isRange ? lo + "–" + f(t.high!) : lo) + unit
        }
        switch (t.metric, t.mode) {
        case (.power, .percent): return ramp + r("% FTP")
        case (.power, .absolute): return ramp + r(" W")
        case (.power, .zone): return ramp + "Z" + r("").replacingOccurrences(of: "–", with: "–Z")
        case (.heartRate, .zone): return ramp + "HR Z" + r("").replacingOccurrences(of: "–", with: "–Z")
        case (.heartRate, _): return ramp + r("% max HR")
        case (.lthr, _): return ramp + r("% LTHR")
        case (.pace, .percent): return ramp + r("% threshold pace")
        case (.pace, .absolute): return ramp + r("/km")
        case (.pace, .zone): return ramp + "Pace Z" + r("").replacingOccurrences(of: "–", with: "–Z")
        }
    }

    static func detail(_ s: PlanStep, includeLength: Bool) -> String {
        var parts: [String] = []
        if includeLength { parts.append(length(s.length)) }
        parts.append(s.target.map(target) ?? "No target")
        if let c = s.cadence { parts.append(c.high.map { "\(c.low)–\($0) rpm" } ?? "\(c.low) rpm") }
        if !s.extra.isEmpty { parts.append(s.extra) }
        return parts.joined(separator: " · ")
    }
}

/// The workout's shape: a bar per step (sloped for ramps), height by intensity, with the threshold
/// line. Tap a bar to pick its step.
struct StructureChart: View {
    let segments: [PlanSegment]
    let selected: UUID?
    let onTap: (UUID) -> Void

    var body: some View {
        GeometryReader { geo in
            let total = max(segments.last?.end ?? 1, 1)
            let peak = max(1.25, (segments.map { max($0.from, $0.to) }.max() ?? 1) * 1.08)
            Canvas { ctx, size in
                let x: (Double) -> CGFloat = { CGFloat($0 / total) * size.width }
                let y: (Double) -> CGFloat = { size.height * (1 - CGFloat($0 / peak)) }

                for s in segments {
                    var path = Path()
                    let x0 = x(s.start), x1 = max(x(s.end), x0 + 0.8)
                    path.move(to: CGPoint(x: x0, y: size.height))
                    path.addLine(to: CGPoint(x: x0, y: y(s.from)))
                    path.addLine(to: CGPoint(x: x1, y: y(s.to)))
                    path.addLine(to: CGPoint(x: x1, y: size.height))
                    path.closeSubpath()
                    let shade: Color
                    if s.stepId == selected {
                        shade = Brand.Medal.gold.flat
                    } else if !s.hasTarget {
                        shade = Brand.sage.opacity(0.5)
                    } else {
                        shade = Brand.forest.opacity(0.3 + 0.65 * min((s.from + s.to) / 2 / 1.3, 1))
                    }
                    ctx.fill(path, with: .color(shade))
                    // A hairline gap between steps.
                    ctx.stroke(Path { p in
                        p.move(to: CGPoint(x: x1, y: size.height))
                        p.addLine(to: CGPoint(x: x1, y: y(s.to)))
                    }, with: .color(Color(.systemBackground).opacity(0.6)), lineWidth: 0.5)
                }

                var threshold = Path()
                threshold.move(to: CGPoint(x: 0, y: y(1)))
                threshold.addLine(to: CGPoint(x: size.width, y: y(1)))
                ctx.stroke(threshold, with: .color(Brand.hairline.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
            }
            .contentShape(Rectangle())
            .onTapGesture { point in
                let t = Double(point.x / max(geo.size.width, 1)) * total
                if let hit = segments.first(where: { t >= $0.start && t < $0.end }) ?? segments.last {
                    onTap(hit.stepId)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Workout structure, \(segments.count) steps")
        }
    }
}
