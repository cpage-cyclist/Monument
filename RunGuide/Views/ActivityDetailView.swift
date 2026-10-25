import SwiftUI
import Charts
import RunGuideCore

/// One activity: summary figures, stacked charts on a shared timeline, a breakdown panel
/// for whatever is selected, peak efforts, and the laps table.
/// Drag on a chart to scrub; press and hold, then drag, to select a range; tap a chart to go
/// back to the whole activity. Tap a lap, peak or W' effort to select it.
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
    @State private var ranks: BestEffortRanks?

    private var smoothing: Smoothing { Smoothing(rawValue: smoothingRaw) ?? .s3 }
    private var wbalSource: WbalSource { WbalSource(rawValue: wbalSourceRaw) ?? .intervals }
    private var current: ActivitySummary { detail?.summary ?? summary }

    /// Bottom panel tabs.
    enum Tab: String, CaseIterable, Identifiable {
        case selection = "Selection", laps = "Laps", peaks = "Peaks", summary = "Summary"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .selection
    @AppStorage("overlaysRide") private var rideOverlays = "power,wbal,heartRate"
    @AppStorage("overlaysRun") private var runOverlays = "pace,heartRate,altitude"

    /// The series switched on for this sport, in chart order, among those this activity has.
    private func visible(_ stack: ChartStack) -> [ChartKind] {
        let chosen = Set((current.isRun ? runOverlays : rideOverlays).split(separator: ",").map(String.init))
        let shown = stack.panels.map(\.kind).filter { chosen.contains($0.rawValue) }
        return shown.isEmpty ? Array(stack.panels.map(\.kind).prefix(1)) : shown
    }

    private func toggle(_ kind: ChartKind, in stack: ChartStack) {
        var set = Set(visible(stack).map(\.rawValue))
        if set.contains(kind.rawValue) {
            guard set.count > 1 else { return }
            set.remove(kind.rawValue)
        } else {
            set.insert(kind.rawValue)
        }
        let joined = ChartKind.allCases.map(\.rawValue).filter(set.contains).joined(separator: ",")
        if current.isRun { runOverlays = joined } else { rideOverlays = joined }
    }

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 10) {
                KeyFigures(summary: current)

                if let analysis {
                    overlayChart(analysis.stack)
                        .frame(maxHeight: .infinity)
                    bottomPanel(analysis)
                        .frame(height: max(geo.size.height * 0.36, 210))
                } else if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ProgressView("Loading charts…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .navigationTitle(current.name ?? "Activity")
        .navigationBarTitleDisplayMode(.inline)
        .brandPageBackground()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    logging = true
                } label: {
                    Label(current.isLogged ? "Edit log" : "Log", systemImage: current.isLogged ? "checkmark.circle" : "square.and.pencil")
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button { Task { await load(force: true) } } label: { Label("Reload", systemImage: "arrow.clockwise") }
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
        .onChange(of: selection) { _, new in
            updateBreakdown()
            if new != nil { withAnimation { tab = .selection } }
        }
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

    // MARK: - Chart

    @ViewBuilder
    private func overlayChart(_ stack: ChartStack) -> some View {
        let scrubIndex = scrubX.flatMap { stack.timeline.index(atX: $0) }
        let highlight = rangeX ?? highlightRange(stack.timeline)
        let kinds = visible(stack)
        VStack(alignment: .leading, spacing: 8) {
            // Overlay switches and smoothing.
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(stack.panels) { panel in
                            let on = kinds.contains(panel.kind)
                            Button { withAnimation(.snappy) { toggle(panel.kind, in: stack) } } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(OverlayChart.color(panel.kind)).frame(width: 7, height: 7)
                                    Text(panel.kind == .heartRate ? "HR" : panel.kind.title)
                                        .font(.brand(.caption, weight: on ? .bold : .medium))
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .foregroundStyle(on ? Color.white : Color.primary)
                                .background(on ? Brand.forest : Color.clear, in: Capsule())
                                .overlay { Capsule().strokeBorder(Brand.hairline.opacity(on ? 0 : 0.4), lineWidth: 1) }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? [.isSelected] : [])
                        }
                    }
                }
                Picker("Smoothing", selection: $smoothingRaw) {
                    ForEach(Smoothing.allCases) { s in Text(s.label).tag(s.rawValue) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            // What's under the finger, or what's selected.
            HStack(spacing: 10) {
                if let i = scrubIndex {
                    Text(Format.clock(stack.timeline.x[i])).font(.caption.monospacedDigit().weight(.semibold))
                    ForEach(kinds) { k in
                        if let panel = stack.panels.first(where: { $0.kind == k }) {
                            Text(k.format(panel.value(at: i)) + " " + k.unit)
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(OverlayChart.color(k))
                        }
                    }
                } else {
                    Text(selection == nil ? "Drag to scrub · hold to select · tap to reset"
                                         : (analysis.map(selectionTitle) ?? "Selection"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            if stack.panels.isEmpty {
                Text("No chartable data was recorded for this activity.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                OverlayChart(stack: stack,
                             kinds: kinds,
                             wbal: kinds.contains(.wbal) ? analysis?.wbal.map { WbalMarks($0, timeline: stack.timeline) } : nil,
                             comparison: kinds.contains(.wbal) ? analysis?.comparison : nil,
                             scrubX: $scrubX,
                             rangeX: $rangeX,
                             highlight: highlight,
                             onSelect: { range in
                                 if range.upperBound - range.lowerBound >= 2 { selection = .range(range) }
                             },
                             onTap: { selection = nil })
            }
        }
    }

    // MARK: - Bottom panel

    private func bottomPanel(_ analysis: Analysis) -> some View {
        VStack(spacing: 8) {
            Picker("Show", selection: $tab) {
                ForEach(Tab.allCases) { t in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented)

            // The page never scrolls; a long table scrolls inside its own panel.
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case .selection:
                        BreakdownPanel(title: selectionTitle(analysis),
                                       stats: breakdown,
                                       isRun: current.isRun,
                                       canClear: selection != nil,
                                       onClear: { selection = nil })
                    case .laps:
                        if let detail, !detail.intervals.isEmpty {
                            LapsTable(intervals: detail.intervals, isRun: current.isRun, selected: lapBinding)
                        } else {
                            Text("No laps recorded.").font(.footnote).foregroundStyle(.secondary)
                        }
                    case .peaks:
                        if !analysis.peaks.isEmpty {
                            PeaksRow(peaks: analysis.peaks, medals: medals(for: analysis.peaks), selected: selectedPeak) { seconds in
                                selection = (selection == .peak(seconds)) ? nil : .peak(seconds)
                            }
                        }
                        if let wbal = analysis.wbal, !wbal.efforts.isEmpty {
                            EffortsRow(efforts: wbal.efforts, timeline: analysis.stack.timeline, selected: selectedEffort) { i in
                                selection = (selection == .effort(i)) ? nil : .effort(i)
                            }
                        }
                        if analysis.peaks.isEmpty && (analysis.wbal?.efforts.isEmpty ?? true) {
                            Text("No power peaks for this activity.").font(.footnote).foregroundStyle(.secondary)
                        }
                    case .summary:
                        SummaryGrid(summary: current)
                        if analysis.stack.panels.contains(where: { $0.kind == .wbal }) {
                            WbalSourceBar(source: $wbalSourceRaw,
                                          profile: profile,
                                          profileLoaded: profileLoaded,
                                          usingMonument: analysis.usingMonument,
                                          intervalsFTP: current.ftp,
                                          intervalsWPrime: streams?[.wbal]?.compactMap { $0 }.max())
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
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
        if ranks == nil, streams?.has(.watts) == true, !current.isRun {
            ranks = await library.bestEffortRanks()
        }
    }

    /// Year / all-time top-three medals for this ride's peaks, keyed by duration.
    private func medals(for peaks: [PeakEffort]) -> [Int: EffortMedal] {
        guard let ranks else { return [:] }
        var out: [Int: EffortMedal] = [:]
        for p in peaks {
            if let m = ranks.medal(activity: summary.id.value, seconds: p.seconds) { out[p.seconds] = m }
        }
        return out
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

/// One panel: the plotted data (redrawn only when the data changes) with a light overlay on
/// top for the scrub line, the selection shading and the touch handling. Keeping the
/// overlay separate means dragging doesn't redraw thousands of chart marks every frame.
/// One chart with every chosen series overlaid on the full height, each on its own scale (the
/// first series' axis is labelled). Drag to scrub; press and hold, then drag, to select a range;
/// tap to clear the selection.
struct OverlayChart: View {
    let stack: ChartStack
    let kinds: [ChartKind]
    var wbal: WbalMarks? = nil
    /// Intervals' W'bal drawn dashed when comparing.
    var comparison: [ChartPoint]? = nil
    @Binding var scrubX: Double?
    @Binding var rangeX: ClosedRange<Double>?
    let highlight: ClosedRange<Double>?
    var onSelect: (ClosedRange<Double>) -> Void = { _ in }
    var onTap: () -> Void = {}

    @State private var plotFrame: CGRect = .zero
    @State private var selecting = false
    @State private var selectStartX: Double?
    @State private var holdFeedback = 0

    private var domain: ClosedRange<Double> { 0...max(stack.timeline.duration, 1) }

    /// Each visible series mapped to 0–1, with the domain it was mapped from.
    private var series: [OverlayPlot.Series] {
        kinds.compactMap { kind in
            guard let panel = stack.panels.first(where: { $0.kind == kind }) else { return nil }
            let extra = kind == .wbal ? (comparison ?? []) : []
            let d = kind.yDomain(for: panel.points + extra)
            func map(_ pts: [ChartPoint]) -> [ChartPoint] {
                pts.map { ChartPoint(x: $0.x, y: kind.normalized($0.y, in: d)) }
            }
            return OverlayPlot.Series(kind: kind, domain: d, points: map(panel.points),
                                      comparison: kind == .wbal ? comparison.map(map) : nil)
        }
    }

    var body: some View {
        let all = series
        OverlayPlot(series: all,
                    wbal: wbal.map { marks in
                        guard let d = all.first(where: { $0.kind == .wbal })?.domain else { return marks }
                        return marks.normalized { ChartKind.wbal.normalized($0, in: d) }
                    },
                    domain: domain)
            .equatable()
            .onPreferenceChange(PlotFrameKey.self) { plotFrame = $0 }
            .overlay(alignment: .topLeading) { overlay }
            .sensoryFeedback(.impact(weight: .medium), trigger: holdFeedback)
            .padding(.vertical, 6)
            .accessibilityLabel("Chart of " + kinds.map(\.title).joined(separator: ", "))
    }

    private var overlay: some View {
        ZStack(alignment: .topLeading) {
            if let highlight, plotFrame.width > 0 {
                let a = position(of: highlight.lowerBound), b = position(of: highlight.upperBound)
                Rectangle()
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: max(b - a, 1), height: plotFrame.height)
                    .offset(x: a, y: plotFrame.minY)
            }
            if let scrubX, plotFrame.width > 0 {
                Rectangle()
                    .fill(Color.primary.opacity(0.5))
                    .frame(width: 1, height: plotFrame.height)
                    .offset(x: position(of: scrubX) - 0.5, y: plotFrame.minY)
            }
            Color.clear
                .contentShape(Rectangle())
                .simultaneousGesture(scrubGesture)
                .simultaneousGesture(selectGesture)
                .simultaneousGesture(TapGesture().onEnded { onTap() })
        }
    }

    private var span: Double { max(domain.upperBound - domain.lowerBound, 1) }

    private func position(of time: Double) -> CGFloat {
        plotFrame.minX + CGFloat((time - domain.lowerBound) / span) * plotFrame.width
    }

    private func time(at point: CGPoint) -> Double? {
        guard plotFrame.width > 0 else { return nil }
        let f = min(max((point.x - plotFrame.minX) / plotFrame.width, 0), 1)
        return domain.lowerBound + Double(f) * span
    }

    /// The page doesn't scroll, so any drag scrubs.
    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard !selecting else { return }
                scrubX = time(at: value.location)
            }
            .onEnded { _ in
                if !selecting { scrubX = nil }
            }
    }

    private var selectGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.35, maximumDistance: 14)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if !selecting {
                    selecting = true
                    holdFeedback += 1
                }
                guard let drag else { return }
                if selectStartX == nil { selectStartX = time(at: drag.startLocation) }
                guard let start = selectStartX, let current = time(at: drag.location) else { return }
                scrubX = current
                rangeX = min(start, current)...max(start, current)
            }
            .onEnded { _ in
                if let range = rangeX { onSelect(range) }
                selecting = false
                selectStartX = nil
                scrubX = nil
                rangeX = nil
            }
    }

    static func color(_ kind: ChartKind) -> Color {
        switch kind {
        // Deep, saturated tones that hold up on the sage page.
        case .power: return Brand.forest
        case .wbal: return .white
        case .heartRate: return Color(red: 0.62, green: 0.12, blue: 0.16)
        case .cadence: return Color(red: 0.42, green: 0.35, blue: 0.10)
        case .speed, .pace: return Color(red: 0.10, green: 0.25, blue: 0.45)
        case .altitude: return Color(red: 0.30, green: 0.36, blue: 0.34)
        }
    }
}

/// The plot area's frame inside a chart, reported up so the overlay can line up with it.
struct PlotFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// The marks: altitude and W'bal as shaded areas underneath, the rest as lines, all on 0–1.
/// Equatable so SwiftUI skips redrawing while the scrub line moves.
struct OverlayPlot: View, Equatable {
    struct Series: Equatable {
        let kind: ChartKind
        let domain: ClosedRange<Double>
        let points: [ChartPoint]
        let comparison: [ChartPoint]?
    }

    let series: [Series]
    let wbal: WbalMarks?
    let domain: ClosedRange<Double>

    /// Axis labels belong to the first series shown.
    private var primary: Series? { series.first }

    var body: some View {
        Chart {
            ForEach(series, id: \.kind) { s in
                let colour = OverlayChart.color(s.kind)
                ForEach(s.points, id: \.x) { p in
                    if s.kind == .altitude || s.kind == .wbal {
                        AreaMark(x: .value("Time", p.x), y: .value("Value", p.y),
                                 series: .value("Series", s.kind.rawValue + "-area"), stacking: .unstacked)
                            .foregroundStyle(colour.opacity(s.kind == .altitude ? 0.18 : 0.22))
                    }
                    LineMark(x: .value("Time", p.x), y: .value("Value", p.y),
                             series: .value("Series", s.kind.rawValue))
                        .foregroundStyle(colour)
                        .lineStyle(StrokeStyle(lineWidth: s.kind == .power ? 1.1 : 1.3))
                }
                if let comparison = s.comparison {
                    ForEach(comparison, id: \.x) { p in
                        LineMark(x: .value("Time", p.x), y: .value("Value", p.y),
                                 series: .value("Series", s.kind.rawValue + "-comparison"))
                            .foregroundStyle(Color.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
            }

            if let wbal {
                ForEach(wbal.efforts, id: \.x) { e in
                    PointMark(x: .value("Time", e.x), y: .value("Value", e.y))
                        .symbolSize(16)
                        .foregroundStyle(OverlayChart.color(.wbal))
                        .annotation(position: .bottom, spacing: 1) {
                            Text("−" + String(format: "%.1f", e.spent))
                                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                }
                PointMark(x: .value("Time", wbal.low.x), y: .value("Value", wbal.low.y))
                    .symbolSize(40)
                    .foregroundStyle(.red)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...1.02)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let s = value.as(Double.self) { Text(Format.clock(s)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 0.25, 0.5, 0.75, 1]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let f = value.as(Double.self), let p = primary {
                        Text(p.kind.axisLabel(p.kind.value(atNormalized: f, in: p.domain)))
                            .foregroundStyle(OverlayChart.color(p.kind))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Color.clear.preference(key: PlotFrameKey.self, value: proxy.plotFrame.map { geo[$0] } ?? .zero)
            }
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
        .overlay { Rectangle().strokeBorder(Brand.hairline, lineWidth: 1) }
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
struct WbalMarks: Equatable {
    struct Mark: Equatable { let x: Double; let y: Double; let spent: Double }
    struct Point: Equatable { let x: Double; let y: Double }
    let low: Point
    let efforts: [Mark]

    private init(low: Point, efforts: [Mark]) {
        self.low = low
        self.efforts = efforts
    }

    /// The same marks with heights mapped onto the overlay chart's 0–1 scale.
    func normalized(_ f: (Double) -> Double) -> WbalMarks {
        WbalMarks(low: Point(x: low.x, y: f(low.y)),
                  efforts: efforts.map { Mark(x: $0.x, y: f($0.y), spent: $0.spent) })
    }

    init(_ analysis: WbalAnalysis, timeline: Timeline) {
        let x = timeline.x
        low = Point(x: x[safe: analysis.lowIndex] ?? 0, y: analysis.lowKJ)
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
                            .background(selected == i ? Color.accentColor.opacity(0.2) : Color.white.opacity(0.35),
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
    var medals: [Int: EffortMedal] = [:]
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
                                HStack(spacing: 4) {
                                    Text(p.label).font(.caption).foregroundStyle(.secondary)
                                    if let medal = medals[p.seconds] { MedalBadge(medal: medal) }
                                }
                                Text("\(Int(p.watts.rounded()))").font(.headline.monospacedDigit())
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityHint(medals[p.seconds]?.description ?? "")
                            .frame(minWidth: 52)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 6)
                            .background(selected == p.seconds ? Color.accentColor.opacity(0.2) : Color.white.opacity(0.35),
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

/// The few figures worth seeing at once, above the chart; the rest are in the Summary tab.
struct KeyFigures: View {
    let summary: ActivitySummary

    var body: some View {
        HStack(alignment: .top) {
            ForEach(figures, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.brand(.caption2)).foregroundStyle(.secondary)
                    Text(value).font(.brand(.headline, weight: .bold).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var figures: [(String, String)] {
        let s = summary
        var out: [(String, String)] = []
        if let t = s.movingTime, t > 0 { out.append(("Time", Format.clock(t))) }
        if let d = s.distance, d > 0 { out.append(("Distance", String(format: "%.1f km", d / 1000))) }
        if s.isRun, let d = s.distance, let t = s.movingTime, d > 0 {
            out.append(("Pace", Format.pace(t / (d / 1000)) + "/km"))
        } else if let np = s.normalizedPower, np > 0 {
            out.append(("NP", "\(Int(np.rounded())) W"))
        } else if let hr = s.averageHeartRate {
            out.append(("Avg HR", "\(Int(hr.rounded()))"))
        }
        if let l = s.trainingLoad { out.append(("Load", "\(Int(l.rounded()))")) }
        return out
    }
}

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
        if let rate = s.carbsPerHour { out.append(Stat(label: "Carbs", value: "\(Int(rate.rounded())) g/h")) }
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
