import SwiftUI
import Charts
import RunGuideCore

/// One activity: summary figures, stacked charts on a shared timeline, and the laps table.
/// Drag across any chart to scrub; the line and readouts move on every panel together.
struct ActivityDetailView: View {
    let summary: ActivitySummary

    @EnvironmentObject private var library: ActivityLibrary
    @AppStorage("chartSmoothing") private var smoothingRaw = Smoothing.s3.rawValue

    @State private var detail: ActivityDetail?
    @State private var streams: ActivityStreams?
    @State private var stack: ChartStack?
    @State private var scrubX: Double?
    @State private var highlightedLap: Int?
    @State private var errorText: String?

    private var smoothing: Smoothing { Smoothing(rawValue: smoothingRaw) ?? .s3 }
    private var current: ActivitySummary { detail?.summary ?? summary }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SummaryGrid(summary: current)

                if let stack {
                    charts(stack)
                } else if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView("Loading charts…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                }

                if let detail, !detail.intervals.isEmpty {
                    LapsTable(intervals: detail.intervals, isRun: current.isRun, selected: $highlightedLap)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle(current.name ?? "Activity")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: smoothingRaw) { _, _ in Task { await rebuild() } }
        .refreshable { await load(force: true) }
    }

    // MARK: - Charts

    @ViewBuilder
    private func charts(_ stack: ChartStack) -> some View {
        let scrubIndex = scrubX.flatMap { stack.timeline.index(atX: $0) }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(scrubIndex.map { Format.clock(stack.timeline.x[$0]) } ?? "Drag a chart to scrub")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(scrubIndex == nil ? .secondary : .primary)
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
                               scrubIndex: scrubIndex,
                               highlight: highlightRange(in: stack.timeline),
                               showXAxis: panel.id == stack.panels.last?.id)
            }
        }
    }

    private func highlightRange(in timeline: Timeline) -> ClosedRange<Double>? {
        guard let i = highlightedLap, let lap = detail?.intervals[safe: i] else { return nil }
        let start: Double?
        let end: Double?
        if let s = lap.startIndex, let e = lap.endIndex, timeline.x.indices.contains(s), timeline.x.indices.contains(e) {
            start = timeline.x[s]
            end = timeline.x[e]
        } else {
            start = lap.startTime.flatMap(timeline.x(atTime:))
            let endTime = lap.endTime ?? lap.startTime.map { $0 + (lap.elapsedTime ?? lap.movingTime ?? 0) }
            end = endTime.flatMap(timeline.x(atTime:))
        }
        guard let start, let end, end > start else { return nil }
        return start...end
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
            if stack == nil { errorText = error.localizedDescription }
        }
        if let fresh = try? await library.detail(id: id, force: force) {
            detail = fresh
        }
    }

    private func rebuild() async {
        guard let streams else { return }
        let isRun = current.isRun
        let smoothing = self.smoothing
        stack = await Task.detached(priority: .userInitiated) {
            ChartStack(streams: streams, isRun: isRun, smoothing: smoothing)
        }.value
    }
}

// MARK: - One chart panel

struct ChartPanelView: View {
    let panel: ChartStack.Panel
    let domain: ClosedRange<Double>
    @Binding var scrubX: Double?
    let scrubIndex: Int?
    let highlight: ClosedRange<Double>?
    let showXAxis: Bool

    private var kind: ChartKind { panel.kind }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
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
                        .foregroundStyle(Color.accentColor.opacity(0.14))
                }

                ForEach(panel.points, id: \.x) { p in
                    if kind == .altitude || kind == .wbal {
                        AreaMark(x: .value("Time", p.x), y: .value(kind.title, p.y))
                            .foregroundStyle(ChartPanelView.color(kind).opacity(0.25))
                        LineMark(x: .value("Time", p.x), y: .value(kind.title, p.y))
                            .foregroundStyle(ChartPanelView.color(kind))
                            .lineStyle(StrokeStyle(lineWidth: 1.2))
                    } else {
                        LineMark(x: .value("Time", p.x), y: .value(kind.title, p.y))
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
            .chartYScale(domain: .automatic(includesZero: kind == .power || kind == .wbal, reversed: kind.reversed))
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
                        if let v = value.as(Double.self) {
                            Text(kind == .pace ? Format.pace(v) : kind.format(v))
                        }
                    }
                }
            }
            .chartXSelection(value: $scrubX)
            .frame(height: kind == .altitude ? 72 : 96)
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
            Text("Tap a row to highlight it on the charts.")
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
            Text(lap.label ?? (lap.isWork ? "Work \(i + 1)" : "Rec \(i + 1)"))
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
