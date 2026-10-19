import SwiftUI
import Charts
import RunGuideCore

/// One activity: summary figures, stacked charts on a shared timeline, a breakdown panel
/// for whatever is selected, peak efforts, and the laps table.
/// Drag on a chart to scrub; press and hold, then drag, to select a range; tap a lap, peak
/// or W' effort to select it.
struct ActivityDetailView: View {
    let summary: ActivitySummary

    @EnvironmentObject private var library: ActivityLibrary
    @AppStorage("chartSmoothing") private var smoothingRaw = Smoothing.s3.rawValue
    @AppStorage("wbalSource") private var wbalSourceRaw = WbalSource.intervals.rawValue

    /// Whose W'bal the chart, efforts and breakdown use.
    enum WbalSource: String, CaseIterable, Identifiable {
        /// Intervals' own stream, from the FTP and W' set by hand in Intervals.
        case intervals
        /// Monument's model with a profile fitted to recent best efforts.
        case monument
        /// Monument's, with Intervals' drawn alongside for comparison.
        case both

        var id: String { rawValue }
        var label: String {
            switch self {
            case .intervals: return "Intervals"
            case .monument: return "Monument"
            case .both: return "Both"
            }
        }
    }

    enum Selection: Equatable {
        case lap(Int)
        case range(ClosedRange<Double>)
        case peak(Int)
        case effort(Int)
    }

    /// Built off the main thread whenever the streams or smoothing change.
    struct Analysis: Sendable {
        let stack: ChartStack
        let peaks: [PeakEffort]
        let wbal: WbalAnalysis?
        /// The streams the charts and breakdown were built from (W'bal swapped for Monument's
        /// when that's chosen).
        let streams: ActivityStreams
        /// Intervals' W'bal in kJ, drawn dashed when comparing.
        let comparison: [ChartPoint]?
        /// True if Monument's W'bal is the one shown.
        let usingMonument: Bool
    }

    @State private var detail: ActivityDetail?
    @State private var streams: ActivityStreams?
    @State private var analysis: Analysis?
    @State private var scrubX: Double?
    @State private var rangeX: ClosedRange<Double>?
    @State private var selection: Selection?
    @State private var breakdown: SelectionStats?
    @State private var errorText: String?
    @State private var logging = false
    @State private var profile: PowerProfile?
    @State private var profileLoaded = false

    private var smoothing: Smoothing { Smoothing(rawValue: smoothingRaw) ?? .s3 }
    private var wbalSource: WbalSource { WbalSource(rawValue: wbalSourceRaw) ?? .intervals }
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
                    if let wbal = analysis.wbal, !wbal.efforts.isEmpty {
                        EffortsRow(efforts: wbal.efforts, timeline: analysis.stack.timeline, selected: selectedEffort) { i in
                            selection = (selection == .effort(i)) ? nil : .effort(i)
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
        .toolbar {
            Button {
                logging = true
            } label: {
                Label(current.isLogged ? "Edit log" : "Log", systemImage: current.isLogged ? "checkmark.circle" : "square.and.pencil")
            }
        }
        .sheet(isPresented: $logging) {
            QuickLogView(activity: current) {
                Task { if let fresh = try? await library.detail(id: summary.id.value, force: true) { detail = fresh } }
            }
            .environmentObject(library)
        }
        .task { await load() }
        .onChange(of: smoothingRaw) { _, _ in Task { await rebuild() } }
        .onChange(of: wbalSourceRaw) { _, _ in Task { await rebuild() } }
        .onChange(of: selection) { _, _ in updateBreakdown() }
        .onChange(of: rangeX) { _, range in
            // The dragged range clears when the finger lifts; keep what was chosen.
            if let range, range.upperBound - range.lowerBound >= 2 { selection = .range(range) }
        }
        .refreshable { await load(force: true) }
    }

    private var selectedPeak: Int? {
        if case .peak(let s) = selection { return s }
        return nil
    }

    private var selectedEffort: Int? {
        if case .effort(let i) = selection { return i }
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
                Text(scrubIndex.map { Format.clock(stack.timeline.x[$0]) } ?? "Drag to scrub · hold, then drag to select")
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
                               showXAxis: panel.id == stack.panels.last?.id,
                               wbal: panel.kind == .wbal ? analysis?.wbal.map { WbalMarks($0, timeline: stack.timeline) } : nil,
                               comparison: panel.kind == .wbal ? analysis?.comparison : nil)
                if panel.kind == .wbal {
                    WbalSourceBar(source: $wbalSourceRaw,
                                  profile: profile,
                                  profileLoaded: profileLoaded,
                                  usingMonument: analysis?.usingMonument ?? false,
                                  intervalsFTP: current.ftp,
                                  intervalsWPrime: streams?[.wbal]?.compactMap { $0 }.max())
                }
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
        case .effort(let i):
            guard let e = analysis?.wbal?.efforts[safe: i], e.endIndex > e.startIndex else { return nil }
            return e.startIndex...e.endIndex
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
        case .effort(let i):
            guard let e = analysis.wbal?.efforts[safe: i] else { return "Effort" }
            return "Effort \(i + 1) · " + String(format: "%.1f kJ", e.spentKJ)
        case .range:
            guard let r = indexRange(timeline) else { return "Selection" }
            return "Selection " + Format.clock(timeline.x[r.lowerBound]) + "–" + Format.clock(timeline.x[r.upperBound])
        }
    }

    private func updateBreakdown() {
        guard let analysis, let range = indexRange(analysis.stack.timeline) else {
            breakdown = nil
            return
        }
        breakdown = SelectionStats.compute(streams: analysis.streams, timeline: analysis.stack.timeline, range: range,
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
        if !profileLoaded, streams?.has(.watts) == true, !current.isRun {
            profile = await library.profile(for: current)
            profileLoaded = true
            if wbalSource != .intervals { await rebuild() }
        }
    }

    private func rebuild() async {
        guard let raw = streams else { return }
        let isRun = current.isRun
        let smoothing = self.smoothing
        let source = wbalSource
        let profile = self.profile
        analysis = await Task.detached(priority: .userInitiated) {
            // Swap in Monument's W'bal when it's chosen and a profile could be fitted.
            var streams = raw
            var usingMonument = false
            if source != .intervals, let profile, raw.has(.watts), let watts = raw[.watts] {
                let balance = WbalModel.skibaDifferential.balance(watts: watts, time: raw.time,
                                                                 cp: profile.cp, wPrime: profile.wPrime)
                if balance.count == raw.count {
                    var series = raw.series
                    series[.wbal] = balance
                    streams = ActivityStreams(time: raw.time, series: series)
                    usingMonument = true
                }
            }
            let stack = ChartStack(streams: streams, isRun: isRun, smoothing: smoothing)
            let peaks = streams.has(.watts)
                ? PeakEffort.find(watts: streams[.watts] ?? [], timeline: stack.timeline)
                : []
            let wbal = streams.has(.watts) && streams.has(.wbal)
                ? WbalAnalysis.analyse(wbal: streams[.wbal] ?? [])
                : nil
            var comparison: [ChartPoint]?
            if source == .both, usingMonument, raw.has(.wbal) {
                comparison = ChartSeries.downsample(x: stack.timeline.x,
                                                    y: ChartKind.wbal.values(from: raw), maxPoints: 600)
            }
            return Analysis(stack: stack, peaks: peaks, wbal: wbal, streams: streams,
                            comparison: comparison, usingMonument: usingMonument)
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
    /// Only set on the W'bal panel.
    var wbal: WbalMarks? = nil
    /// A second line drawn dashed on the same scale (Intervals' W'bal when comparing).
    var comparison: [ChartPoint]? = nil

    /// Press-and-hold selection: hold still briefly, feel the tap, then drag across a range.
    @State private var selecting = false
    @State private var selectStartX: Double?
    /// The first move of a one-finger drag decides between scrubbing (sideways) and
    /// scrolling the page (up/down).
    @State private var dragAxis: Axis?
    @State private var holdFeedback = 0

    private var kind: ChartKind { panel.kind }
    /// Reversed panels (pace) plot negated values so faster sits at the top.
    private var sign: Double { kind.reversed ? -1 : 1 }

    private var yDomain: ClosedRange<Double> {
        let d = kind.yDomain(for: panel.points + (comparison ?? []))
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
                } else if let wbal {
                    Text("Low " + String(format: "%.1f", wbal.low.y) + " kJ")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.red)
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
                        LineMark(x: .value("Time", p.x), y: .value(kind.title, p.y * sign),
                                 series: .value("Series", "main"))
                            .foregroundStyle(ChartPanelView.color(kind))
                            .lineStyle(StrokeStyle(lineWidth: 1.2))
                    } else {
                        LineMark(x: .value("Time", p.x), y: .value(kind.title, p.y * sign),
                                 series: .value("Series", "main"))
                            .foregroundStyle(ChartPanelView.color(kind))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                }

                if let comparison {
                    ForEach(comparison, id: \.x) { p in
                        LineMark(x: .value("Time", p.x), y: .value(kind.title, p.y * sign),
                                 series: .value("Series", "comparison"))
                            .foregroundStyle(Color.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }

                if let wbal {
                    ForEach(wbal.efforts, id: \.x) { e in
                        PointMark(x: .value("Time", e.x), y: .value("W'bal", e.y))
                            .symbolSize(16)
                            .foregroundStyle(ChartPanelView.color(.wbal))
                            .annotation(position: .bottom, spacing: 1) {
                                Text("−" + String(format: "%.1f", e.spent))
                                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                    }
                    PointMark(x: .value("Time", wbal.low.x), y: .value("W'bal", wbal.low.y))
                        .symbolSize(40)
                        .foregroundStyle(.red)
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
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .simultaneousGesture(scrubGesture(proxy, geo))
                        .simultaneousGesture(selectGesture(proxy, geo))
                }
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: holdFeedback)
            .frame(height: kind == .altitude ? 72 : (kind == .wbal ? 110 : 96))
            .clipped()
            .accessibilityLabel(kind.title)
        }
    }

    // MARK: - Gestures

    /// Chart time at a touch point, clamped to the chart.
    private func time(at point: CGPoint, _ proxy: ChartProxy, _ geo: GeometryProxy) -> Double? {
        guard let anchor = proxy.plotFrame else { return nil }
        let frame = geo[anchor]
        let x = min(max(point.x - frame.minX, 0), frame.width)
        guard let value = proxy.value(atX: x, as: Double.self) else { return nil }
        return min(max(value, domain.lowerBound), domain.upperBound)
    }

    private func scrubGesture(_ proxy: ChartProxy, _ geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragAxis == nil {
                    dragAxis = abs(value.translation.width) >= abs(value.translation.height) ? .horizontal : .vertical
                }
                guard dragAxis == .horizontal, !selecting else { return }
                scrubX = time(at: value.location, proxy, geo)
            }
            .onEnded { _ in
                dragAxis = nil
                if !selecting { scrubX = nil }
            }
    }

    private func selectGesture(_ proxy: ChartProxy, _ geo: GeometryProxy) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35, maximumDistance: 14)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if !selecting {
                    selecting = true
                    holdFeedback += 1
                }
                guard let drag else { return }
                if selectStartX == nil { selectStartX = time(at: drag.startLocation, proxy, geo) }
                guard let start = selectStartX, let current = time(at: drag.location, proxy, geo) else { return }
                scrubX = current
                rangeX = min(start, current)...max(start, current)
            }
            .onEnded { _ in
                selecting = false
                selectStartX = nil
                scrubX = nil
                // The detail view has already taken the range as its selection.
                rangeX = nil
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

// MARK: - W'bal

/// Chart positions for the W'bal markers: the lowest point and each labelled effort's low.
struct WbalMarks {
    struct Mark { let x: Double; let y: Double; let spent: Double }
    let low: (x: Double, y: Double)
    let efforts: [Mark]

    init(_ analysis: WbalAnalysis, timeline: Timeline) {
        let x = timeline.x
        low = (x[safe: analysis.lowIndex] ?? 0, analysis.lowKJ)
        efforts = analysis.labelled().compactMap { e in
            x[safe: e.endIndex].map { Mark(x: $0, y: e.lowKJ, spent: e.spentKJ) }
        }
    }
}

struct EffortsRow: View {
    let efforts: [WbalEffort]
    let timeline: Timeline
    let selected: Int?
    let onTap: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("W' efforts").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(efforts.enumerated()), id: \.offset) { i, e in
                        Button { onTap(i) } label: {
                            VStack(spacing: 2) {
                                Text(duration(e)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(String(format: "%.1f", e.spentKJ)).font(.headline.monospacedDigit())
                                Text("to " + String(format: "%.1f", e.lowKJ)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .frame(minWidth: 58)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 6)
                            .background(selected == i ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text("kJ spent from W' in each effort, and the W'bal it dropped to.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func duration(_ e: WbalEffort) -> String {
        guard let a = timeline.x[safe: e.startIndex], let b = timeline.x[safe: e.endIndex] else { return "–" }
        return Format.clock(b - a)
    }
}

// MARK: - W'bal source

/// Switches the W'bal chart between Intervals' (hand-set FTP and W') and Monument's
/// (profile fitted to recent best efforts), and says which numbers are in use.
struct WbalSourceBar: View {
    @Binding var source: String
    let profile: PowerProfile?
    let profileLoaded: Bool
    let usingMonument: Bool
    let intervalsFTP: Double?
    /// Joules: the top of Intervals' W'bal stream, which is the W' it used.
    let intervalsWPrime: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("W'bal source", selection: $source) {
                ForEach(ActivityDetailView.WbalSource.allCases) { s in Text(s.label).tag(s.rawValue) }
            }
            .pickerStyle(.segmented)

            let choice = ActivityDetailView.WbalSource(rawValue: source) ?? .intervals
            if choice != .monument { line(intervalsText, dashed: choice == .both) }
            if choice != .intervals { line(monumentText, dashed: false) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func line(_ text: String, dashed: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if dashed {
                Text("- -").font(.caption.monospaced())
            }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var intervalsText: String {
        var parts = ["Intervals (your settings)"]
        if let ftp = intervalsFTP { parts.append("FTP \(Int(ftp.rounded())) W") }
        if let wp = intervalsWPrime { parts.append(String(format: "W′ %.1f kJ", wp / 1000)) }
        return parts.joined(separator: " · ")
    }

    private var monumentText: String {
        guard profileLoaded else { return "Monument: fitting your profile…" }
        guard let p = profile else {
            return "Monument: not enough hard 3–20 min efforts in the 90 days before this ride to fit a profile, so Intervals' W'bal is shown."
        }
        var text = "Monument · CP \(Int(p.cp.rounded())) W · " + String(format: "W′ %.1f kJ", p.wPrime / 1000)
        text += " · fitted to best 3–20 min efforts"
        if let from = p.from, let to = p.to { text += ", " + Self.short(from) + " – " + Self.short(to) }
        if !usingMonument { text += " (not applied: no power data)" }
        return text
    }

    private static func short(_ day: String) -> String {
        IntervalsDates.parseLocal(day + "T12:00:00")?.formatted(.dateTime.day().month(.abbreviated)) ?? day
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
