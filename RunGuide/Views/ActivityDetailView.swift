import SwiftUI
import Charts
import RunGuideCore

/// One activity: summary figures, stacked charts on a shared timeline, a breakdown panel
/// for whatever is selected, peak efforts, and the laps table.
/// Drag on a chart to scrub; drag with two fingers to select a range; tap a lap or a peak
/// to select it.
struct ActivityDetailView: View {
    let summary: ActivitySummary

    @EnvironmentObject private var library: ActivityLibrary
    @AppStorage("chartSmoothing") private var smoothingRaw = Smoothing.s3.rawValue

    enum Selection: Equatable {
        case lap(Int)
        case range(ClosedRange<Double>)
        case peak(Int)
    }

    /// Built off the main thread whenever the streams or smoothing change.
    struct Analysis: Sendable {
        let stack: ChartStack
        let peaks: [PeakEffort]
    }

    @State private var detail: ActivityDetail?
    @State private var streams: ActivityStreams?
    @State private var analysis: Analysis?
    @State private var scrubX: Double?
    @State private var rangeX: ClosedRange<Double>?
    @State private var selection: Selection?
    @State private var breakdown: SelectionStats?
    @State private var errorText: String?

    private var smoothing: Smoothing { Smoothing(rawValue: smoothingRaw) ?? .s3 }
    private var current: ActivitySummary { detail?.summary ?? summary }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SummaryGrid(summary: current)

                if let analysis {
                    charts(analysis.stack)
                    BreakdownPanel(title: selectionTitle(analysis),
                                   stats: breakdown,
                                   isRun: current.isRun,
                                   canClear: selection != nil,
                                   onClear: { selection = nil })
                    if !analysis.peaks.isEmpty {
                        PeaksRow(peaks: analysis.peaks, selected: selectedPeak) { seconds in
                            selection = (selection == .peak(seconds)) ? nil : .peak(seconds)
                        }
                    }
                } else if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView("Loading charts…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                }

                if let detail, !detail.intervals.isEmpty {
                    LapsTable(intervals: detail.intervals, isRun: current.isRun, selected: lapBinding)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle(current.name ?? "Activity")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: smoothingRaw) { _, _ in Task { await rebuild() } }
        .onChange(of: selection) { _, _ in updateBreakdown() }
        .onChange(of: rangeX) { _, range in
            // The two-finger range clears when the fingers lift; keep what was chosen.
            if let range, range.upperBound - range.lowerBound >= 2 { selection = .range(range) }
        }
        .refreshable { await load(force: true) }
    }

    private var selectedPeak: Int? {
        if case .peak(let s) = selection { return s }
        return nil
    }

    private var lapBinding: Binding<Int?> {
        Binding {
            if case .lap(let i) = selection { return i }
            return nil
        } set: { i in
            selection = i.map { .lap($0) }
        }
    }

    // MARK: - Charts

    @ViewBuilder
    private func charts(_ stack: ChartStack) -> some View {
        let scrubIndex = scrubX.flatMap { stack.timeline.index(atX: $0) }
        let highlight = highlightRange(stack.timeline)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(scrubIndex.map { Format.clock(stack.timeline.x[$0]) } ?? "Drag to scrub · two fingers to select")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(scrubIndex == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                Picker("Smoothing", selection: $smoothingRaw) {
                    ForEach(Smoothing.allCases) { s in Text(s.label).tag(s.rawValue) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            if stack.panels.isEmpty {
                Text("No chartable data was recorded for this activity.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(stack.panels) { panel in
                ChartPanelView(panel: panel,
                               domain: 0...max(stack.timeline.duration, 1),
                               scrubX: $scrubX,
                               rangeX: $rangeX,
                               scrubIndex: scrubIndex,
                               highlight: highlight,
                               showXAxis: panel.id == stack.panels.last?.id)
            }
        }
    }

    /// Sample indexes the current selection covers.
    private func indexRange(_ timeline: Timeline) -> ClosedRange<Int>? {
        switch selection {
        case nil:
            return timeline.count > 1 ? 0...(timeline.count - 1) : nil
        case .range(let r):
            guard let a = timeline.index(atX: r.lowerBound), let b = timeline.index(atX: r.upperBound), b > a else { return nil }
            return a...b
        case .peak(let seconds):
            return analysis?.peaks.first { $0.seconds == seconds }?.range
        case .lap(let i):
            guard let lap = detail?.intervals[safe: i] else { return nil }
            if let s = lap.startIndex, let e = lap.endIndex, timeline.x.indices.contains(s), timeline.x.indices.contains(e), e > s {
                return s...e
            }
            guard let startTime = lap.startTime, let a = timeline.index(atTime: startTime) else { return nil }
            let endTime = lap.endTime ?? startTime + (lap.elapsedTime ?? lap.movingTime ?? 0)
            guard let b = timeline.index(atTime: endTime), b > a else { return nil }
            return a...b
        }
    }

    private func highlightRange(_ timeline: Timeline) -> ClosedRange<Double>? {
        guard selection != nil, let r = indexRange(timeline) else { return nil }
        return timeline.x[r.lowerBound]...timeline.x[r.upperBound]
    }

    private func selectionTitle(_ analysis: Analysis) -> String {
        let timeline = analysis.stack.timeline
        switch selection {
        case nil:
            return "Whole activity"
        case .lap(let i):
            return detail?.intervals[safe: i]?.label ?? "Lap \(i + 1)"
        case .peak(let seconds):
            guard let p = analysis.peaks.first(where: { $0.seconds == seconds }) else { return "Peak" }
            return "Best \(p.label) · \(Int(p.watts.rounded())) W"
        case .range:
            guard let r = indexRange(timeline) else { return "Selection" }
            return "Selection " + Format.clock(timeline.x[r.lowerBound]) + "–" + Format.clock(timeline.x[r.upperBound])
        }
    }

    private func updateBreakdown() {
        guard let streams, let analysis, let range = indexRange(analysis.stack.timeline) else {
            breakdown = nil
            return
        }
        breakdown = SelectionStats.compute(streams: streams, timeline: analysis.stack.timeline, range: range,
                                           ftp: current.ftp, weight: current.weight, isRun: current.isRun)
    }

    // MARK: - Loading

    private func load(force: Bool = false) async {
        let id = summary.id.value
        if detail == nil { detail = library.cachedDetail(id: id) }
        do {
            if streams == nil || force {
                streams = try await library.streams(id: id)
                await rebuild()
            }
            errorText = nil
        } catch {
            if analysis == nil { errorText = error.localizedDescription }
        }
        if let fresh = try? await library.detail(id: id, force: force) {
            detail = fresh
            updateBreakdown()
        }
    }

    private func rebuild() async {
        guard let streams else { return }
        let isRun = current.isRun
        let smoothing = self.smoothing
        analysis = await Task.detached(priority: .userInitiated) {
            let stack = ChartStack(streams: streams, isRun: isRun, smoothing: smoothing)
            let peaks = streams.has(.watts)
                ? PeakEffort.find(watts: streams[.watts] ?? [], timeline: stack.timeline)
                : []
            return Analysis(stack: stack, peaks: peaks)
        }.value
        updateBreakdown()
    }
}

// MARK: - One chart panel

struct ChartPanelView: View {
    let panel: ChartStack.Panel
    let domain: ClosedRange<Double>
    @Binding var scrubX: Double?
    @Binding var rangeX: ClosedRange<Double>?
    let scrubIndex: Int?
    let highlight: ClosedRange<Double>?
    let showXAxis: Bool

    private var kind: ChartKind { panel.kind }
    /// Reversed panels (pace) plot negated values so faster sits at the top.
    private var sign: Double { kind.reversed ? -1 : 1 }

    private var yDomain: ClosedRange<Double> {
        let d = kind.yDomain(for: panel.points)
        return kind.reversed ? (-d.upperBound)...(-d.lowerBound) : d
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(kind.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if scrubIndex != nil {
                    Text(kind.format(panel.value(at: scrubIndex)) + " " + kind.unit)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(ChartPanelView.color(kind))
                }
            }

            Chart {
                if let highlight {
                    RectangleMark(xStart: .value("Start", highlight.lowerBound),
                                  xEnd: .value("End", highlight.upperBound))
                        .foregroundStyle(Color.accentColor.opacity(0.16))
                }

                ForEach(panel.points, id: \.x) { p in
                    if kind == .altitude || kind == .wbal {
                        AreaMark(x: .value("Time", p.x),
                                 yStart: .value("Base", yDomain.lowerBound),
                                 yEnd: .value(kind.title, p.y * sign))
                            .foregroundStyle(ChartPanelView.color(kind).opacity(0.25))
                        LineMark(x: .value("Time", p.x), y: .value(kind.title, p.y * sign))
                            .foregroundStyle(ChartPanelView.color(kind))
                            .lineStyle(StrokeStyle(lineWidth: 1.2))
                    } else {
                        LineMark(x: .value("Time", p.x), y: .value(kind.title, p.y * sign))
                            .foregroundStyle(ChartPanelView.color(kind))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }

                if let scrubX {
                    RuleMark(x: .value("Time", scrubX))
                        .foregroundStyle(Color.primary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: yDomain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let s = value.as(Double.self) { Text(Format.clock(s)) }
                    }
                }
            }
            .chartXAxis(showXAxis ? .automatic : .hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(kind.axisLabel(v * sign)) }
                    }
                }
            }
            .chartXSelection(value: $scrubX)
            .chartXSelection(range: $rangeX)
            .frame(height: kind == .altitude ? 72 : 96)
            .clipped()
            .accessibilityLabel(kind.title)
        }
    }

    static func color(_ kind: ChartKind) -> Color {
        switch kind {
        case .power: return .indigo
        case .wbal: return .teal
        case .heartRate: return .red
        case .cadence: return .orange
        case .speed, .pace: return .blue
        case .altitude: return .gray
        }
    }
}

// MARK: - Breakdown

/// TrainingPeaks-style breakdown of the selection (or the whole activity).
struct BreakdownPanel: View {
    let title: String
    let stats: SelectionStats?
    let isRun: Bool
    let canClear: Bool
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.title3.weight(.semibold)).lineLimit(1)
                Spacer()
                if canClear {
                    Button("Whole activity", action: onClear)
                        .font(.subheadline)
                }
            }

            if let s = stats {
                HStack(alignment: .top) {
                    bigFigure("Duration", Format.clock(s.duration))
                    bigFigure("Distance", s.distance.map { String(format: "%.2f km", $0 / 1000) } ?? "–")
                    bigFigure("Load", s.load.map { "\(Int($0.rounded()))" } ?? "–")
                }

                let pairs = keyFigures(s)
                if !pairs.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible())], spacing: 8) {
                        ForEach(pairs, id: \.0) { pair in
                            HStack {
                                Text(pair.0).foregroundStyle(.secondary)
                                Spacer()
                                Text(pair.1).monospacedDigit()
                            }
                            .font(.subheadline)
                        }
                    }
                }

                let rows = minAvgMax(s)
                if !rows.isEmpty {
                    Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 7) {
                        GridRow {
                            Text("").gridColumnAlignment(.leading)
                            Text("Min")
                            Text("Avg")
                            Text("Max")
                            Text("")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        ForEach(rows, id: \.label) { row in
                            GridRow {
                                Text(row.label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                                Text(row.min)
                                Text(row.avg).fontWeight(.semibold)
                                Text(row.max)
                                Text(row.unit).font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                            }
                            .font(.subheadline.monospacedDigit())
                        }
                    }
                }
            } else {
                Text("Not enough data in this selection.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func bigFigure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func keyFigures(_ s: SelectionStats) -> [(String, String)] {
        var out: [(String, String)] = []
        func add(_ label: String, _ value: String?) { if let value { out.append((label, value)) } }
        add("Work", s.work.map { "\(Int($0.rounded())) kJ" })
        add("IF", s.intensity.map { String(format: "%.2f", $0) })
        add("NP", s.normalizedPower.map { "\(Int($0.rounded())) W" })
        add("VI", s.variabilityIndex.map { String(format: "%.2f", $0) })
        add("W/kg", s.wattsPerKg.map { String(format: "%.2f", $0) })
        add("El. gain", s.elevationGain.map { "\(Int($0.rounded())) m" })
        add("VAM", s.vam.map { "\(Int($0.rounded())) m/h" })
        add("El. loss", s.elevationLoss.map { "\(Int($0.rounded())) m" })
        add("Grade", s.grade.map { String(format: "%.1f%%", $0) })
        add("Decoupling", s.decoupling.map { String(format: "%.1f%%", $0) })
        add("W'bal start", s.wbalStart.map { String(format: "%.1f kJ", $0) })
        add("W'bal low", s.wbalLow.map { String(format: "%.1f kJ", $0) })
        add("W'bal end", s.wbalEnd.map { String(format: "%.1f kJ", $0) })
        add("W' used", s.wbalUsed.map { String(format: "%.1f kJ", $0) })
        return out
    }

    private struct Row { let label, min, avg, max, unit: String }

    private func minAvgMax(_ s: SelectionStats) -> [Row] {
        var rows: [Row] = []
        func int(_ v: Double) -> String { "\(Int(v.rounded()))" }
        func one(_ v: Double) -> String { String(format: "%.1f", v) }
        if let r = s.power { rows.append(Row(label: "Power", min: int(r.min), avg: int(r.avg), max: int(r.max), unit: "W")) }
        if let r = s.heartRate { rows.append(Row(label: "Heart rate", min: int(r.min), avg: int(r.avg), max: int(r.max), unit: "bpm")) }
        if let r = s.cadence { rows.append(Row(label: "Cadence", min: int(r.min), avg: int(r.avg), max: int(r.max), unit: isRun ? "spm" : "rpm")) }
        if isRun, let r = s.pace {
            rows.append(Row(label: "Pace", min: Format.pace(r.min), avg: Format.pace(r.avg), max: Format.pace(r.max), unit: "/km"))
        } else if let r = s.speed {
            rows.append(Row(label: "Speed", min: one(r.min), avg: one(r.avg), max: one(r.max), unit: "km/h"))
        }
        if let r = s.elevation { rows.append(Row(label: "Elevation", min: int(r.min), avg: int(r.avg), max: int(r.max), unit: "m")) }
        if let r = s.temperature { rows.append(Row(label: "Temperature", min: int(r.min), avg: int(r.avg), max: int(r.max), unit: "°C")) }
        return rows
    }
}

// MARK: - Peaks

struct PeaksRow: View {
    let peaks: [PeakEffort]
    let selected: Int?
    let onTap: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Peak power").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(peaks) { p in
                        Button { onTap(p.seconds) } label: {
                            VStack(spacing: 2) {
                                Text(p.label).font(.caption).foregroundStyle(.secondary)
                                Text("\(Int(p.watts.rounded()))").font(.headline.monospacedDigit())
                            }
                            .frame(minWidth: 52)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 6)
                            .background(selected == p.seconds ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Summary

struct SummaryGrid: View {
    let summary: ActivitySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let date = summary.startDate {
                Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                      alignment: .leading, spacing: 12) {
                ForEach(stats, id: \.label) { stat in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(stat.label).font(.caption).foregroundStyle(.secondary)
                        Text(stat.value).font(.headline.monospacedDigit())
                    }
                }
            }
        }
    }

    private struct Stat { let label: String; let value: String }

    private var stats: [Stat] {
        let s = summary
        var out: [Stat] = []
        if let t = s.movingTime, t > 0 { out.append(Stat(label: "Time", value: Format.clock(t))) }
        if let d = s.distance, d > 0 { out.append(Stat(label: "Distance", value: String(format: "%.2f km", d / 1000))) }
        if let l = s.trainingLoad { out.append(Stat(label: "Load", value: "\(Int(l.rounded()))")) }
        if let np = s.normalizedPower, np > 0 { out.append(Stat(label: "NP", value: "\(Int(np.rounded())) W")) }
        if let ap = s.averagePower, ap > 0 { out.append(Stat(label: "Avg power", value: "\(Int(ap.rounded())) W")) }
        if let i = s.intensity { out.append(Stat(label: "IF", value: String(format: "%.2f", i / 100))) }
        if s.isRun, let d = s.distance, let t = s.movingTime, d > 0 {
            out.append(Stat(label: "Pace", value: Format.pace(t / (d / 1000)) + "/km"))
        }
        if let hr = s.averageHeartRate { out.append(Stat(label: "Avg HR", value: "\(Int(hr.rounded())) bpm")) }
        if let e = s.totalElevationGain, e > 0 { out.append(Stat(label: "Elevation", value: "\(Int(e.rounded())) m")) }
        if let rpe = s.rpe { out.append(Stat(label: "RPE", value: "\(rpe)")) }
        if let feel = s.feel { out.append(Stat(label: "Feel", value: SummaryGrid.feelLabel(feel))) }
        return out
    }

    /// Intervals' feel scale runs 1 (strong) to 5 (weak).
    static func feelLabel(_ feel: Int) -> String {
        switch feel {
        case 1: return "Strong"
        case 2: return "Good"
        case 3: return "Normal"
        case 4: return "Poor"
        case 5: return "Weak"
        default: return "\(feel)"
        }
    }
}

// MARK: - Laps

struct LapsTable: View {
    let intervals: [ActivityInterval]
    let isRun: Bool
    @Binding var selected: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Laps & intervals")
                .font(.headline)
                .padding(.bottom, 6)
            HStack {
                Text("").frame(width: 70, alignment: .leading)
                Text("Time").frame(maxWidth: .infinity, alignment: .trailing)
                Text(isRun ? "Pace" : "Avg W").frame(maxWidth: .infinity, alignment: .trailing)
                Text(isRun ? "Dist" : "NP").frame(maxWidth: .infinity, alignment: .trailing)
                Text("HR").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)

            ForEach(Array(intervals.enumerated()), id: \.offset) { i, lap in
                Button {
                    selected = (selected == i) ? nil : i
                } label: {
                    row(i, lap)
                }
                .buttonStyle(.plain)
                Divider()
            }
            Text("Tap a row for its breakdown.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }

    private func row(_ i: Int, _ lap: ActivityInterval) -> some View {
        let duration = lap.movingTime ?? lap.elapsedTime
        let pace: String = {
            guard let d = lap.distance, let t = duration, d > 0 else { return "–" }
            return Format.pace(t / (d / 1000))
        }()
        return HStack {
            Text(lap.label ?? "Lap \(i + 1)")
                .lineLimit(1)
                .frame(width: 70, alignment: .leading)
                .foregroundStyle(lap.isWork ? .primary : .secondary)
            Text(duration.map(Format.clock) ?? "–").frame(maxWidth: .infinity, alignment: .trailing)
            Text(isRun ? pace : (lap.averagePower.map { "\(Int($0.rounded()))" } ?? "–"))
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(isRun ? (lap.distance.map { String(format: "%.2f", $0 / 1000) } ?? "–")
                       : (lap.normalizedPower.map { "\(Int($0.rounded()))" } ?? "–"))
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(lap.averageHeartRate.map { "\(Int($0.rounded()))" } ?? "–")
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.subheadline.monospacedDigit())
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(selected == i ? Color.accentColor.opacity(0.12) : .clear)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
