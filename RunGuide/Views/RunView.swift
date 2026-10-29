import SwiftUI
import RunGuideCore

struct RunView: View {
    @StateObject private var run: RunController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmEnd = false

    init(workout: Workout, sport: RecordSport, options: EngineOptions, tracker: LocationTracker,
         heartRate: HeartRateMonitor, power: CyclingSensor? = nil, cadence: CyclingSensor? = nil,
         store: RunStore, client: IntervalsClient?,
         route: Route? = nil, loopRoute: Bool = false, strava: StravaAccount? = nil,
         efforts: [RouteEffort] = [], ftp: Double? = nil, effortFeedback: Bool = true) {
        _run = StateObject(wrappedValue: RunController(workout: workout, sport: sport, options: options,
                                                       tracker: tracker, heartRate: heartRate,
                                                       power: power, cadence: cadence,
                                                       store: store, client: client,
                                                       route: route, loopRoute: loopRoute, strava: strava,
                                                       efforts: efforts, ftp: ftp, effortFeedback: effortFeedback))
    }

    var body: some View {
        Group {
            if run.finished {
                SummaryView(run: run) { dismiss() }
            } else {
                live
            }
        }
        .onAppear { run.startIfNeeded() }
    }

    private var engine: SessionEngine { run.engine }

    /// The live screen: what's happening now at the top, the step's countdown as the Akira hero,
    /// sensors and figures in boxes, and the controls on the ridge footer.
    private var live: some View {
        VStack(spacing: 14) {
            HStack {
                Label {
                    Text(engine.isFree
                         ? "\(run.sport.title) · lap \(engine.laps.count + 1)"
                         : "\(run.sport.title) · step \(min(engine.stepIndex + 1, engine.workout.steps.count)) of \(engine.workout.steps.count)")
                } icon: {
                    Image(systemName: run.sport.icon)
                }
                .font(.brand(.caption, weight: .semibold))
                .textCase(.uppercase)
                .tracking(1)
                Spacer()
                Text(Format.clock(engine.totalTime)).font(.num(.subheadline, weight: .medium))
            }
            .padding(.top, 8)

            if let guide = run.guide {
                RouteBanner(guide: guide).id(run.tick)
            }
            if let player = run.effortPlayer {
                EffortBanner(player: player, time: engine.totalTime, ftp: run.ftp).id(run.tick)
            }

            if let step = engine.currentStep {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        if !engine.isFree {
                            Text(step.label).font(.brand(.title2, weight: .semibold)).lineLimit(2)
                        }
                        if let target = step.target {
                            Text(target).font(.num(.subheadline)).foregroundStyle(.secondary)
                        }
                        Text(remainingText(step))
                            .font(.hero(84))
                            .akiraSlant()
                            .foregroundStyle(Brand.wordmark)
                            .padding(.leading, 8)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .padding(.top, 6)
                        if case .open = step.end {} else {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(Brand.forest.opacity(0.18))
                                    Rectangle().fill(Brand.forest).frame(width: geo.size.width * engine.stepProgress)
                                }
                            }
                            .frame(height: 5)
                            .padding(.top, 4)
                        }
                    }
                }
            }

            if run.hasPowerSensors {
                PowerPanel(watts: run.power?.threeSecondWatts, target: run.targetWatts,
                           cadence: run.currentCadence, hasPower: run.power != nil)
            }

            Card {
                HStack(alignment: .top) {
                    stat("Distance", Format.km(engine.totalDistance))
                    if run.sport.usesPace {
                        stat("Pace", Format.pace(run.currentPace))
                    } else {
                        stat("km/h", run.currentSpeed.map { String(format: "%.1f", $0) } ?? "––")
                    }
                    if run.heartRate.hasPairedStrap {
                        stat("HR", run.heartRate.currentBPM.map(String.init) ?? "––")
                    }
                    stat("Step", Format.clock(engine.stepTime))
                }
            }

            if let next = engine.nextStep {
                Text("Next: \(next.label) · \(Format.amount(next.end))")
                    .font(.brand(.callout))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if run.paused {
                Text("Paused").font(.hero(18)).akiraSlant().foregroundStyle(Brand.Data.fatigue)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .safeAreaInset(edge: .bottom, spacing: 0) { controls }
        .background(Brand.page.ignoresSafeArea())
        .confirmationDialog("End the session now?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End session", role: .destructive) { run.end() }
            Button("Keep going", role: .cancel) {}
        }
    }

    /// Pause, Lap and End on the forest band at the foot of the ridges.
    private var controls: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                RidgeStack(spread: Brand.Header.restSpread, width: geo.size.width * Brand.Header.bleed,
                           fills: RidgeFooter.fills)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            }
            .clipped()
            .frame(height: 90)
            HStack(spacing: 10) {
                Button(run.paused ? "Resume" : "Pause") { run.togglePause() }
                    .buttonStyle(FooterButton(kind: .outline))
                Button("Lap") { run.lap() }
                    .buttonStyle(FooterButton(kind: .solid))
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                Button("End") { confirmEnd = true }
                    .buttonStyle(FooterButton(kind: .end))
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .background(Brand.forest.ignoresSafeArea(edges: .bottom))
        }
    }

    private func remainingText(_ step: Step) -> String {
        switch step.end {
        case .distance:
            return Format.remainingDistance(engine.remaining ?? 0)
        case .time:
            return Format.clock((engine.remaining ?? 0).rounded(.up))
        case .open:
            return Format.clock(engine.stepTime)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.brand(.caption)).foregroundStyle(.secondary)
            Text(value).font(.num(.title3, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SummaryView: View {
    @ObservedObject var run: RunController
    let done: () -> Void
    @State private var confirmDiscard = false

    var body: some View {
        NavigationStack {
            BrandList {
                Section {
                    HStack {
                        Text("Total")
                        Spacer()
                        Text("\(Format.km(run.engine.totalDistance)) · \(Format.clock(run.engine.totalTime))")
                            .monospacedDigit()
                    }
                    if run.kept {
                        fileRow
                        uploadRow
                        stravaRow
                    } else if run.saveFailed {
                        Label("Couldn't save the FIT file", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Brand.alert)
                    }
                }
                BrandSection("Laps") {
                    ForEach(Array(run.engine.laps.enumerated()), id: \.offset) { _, lap in
                        HStack {
                            Text(lap.label)
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text("\(Format.km(lap.distance)) · \(Format.clock(lap.duration))")
                                    .monospacedDigit()
                                Text(run.sport.usesPace ? "\(Format.pace(lap.pace))/km"
                                                        : lap.pace.map { String(format: "%.1f km/h", 3600 / $0) } ?? "–")
                                    .font(.brand(.caption))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .ridgeSheetHeader("Done")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: run.summaryText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                if run.kept {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done", action: done)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !run.kept {
                    VStack(spacing: 10) {
                        Button {
                            run.keep()
                        } label: {
                            Text(run.upload == .off ? "Save \(run.sport.title.lowercased())" : "Save and upload")
                                .font(.brand(.headline))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(run.savedRun == nil)

                        Button("Discard \(run.sport.title.lowercased())", role: .destructive) {
                            confirmDiscard = true
                        }
                    }
                    .padding()
                    .background(.bar)
                }
            }
            .confirmationDialog("Discard this \(run.sport.title.lowercased())?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) {
                    run.discard()
                    done()
                }
                Button("Keep it", role: .cancel) {}
            } message: {
                Text("The recording is deleted from your phone and won't be uploaded.")
            }
        }
        .interactiveDismissDisabled(!run.kept)
    }

    @ViewBuilder private var fileRow: some View {
        if let url = run.fileURL {
            ShareLink(item: url) {
                Label("Saved as FIT file", systemImage: "doc.fill")
            }
        }
    }

    @ViewBuilder private var stravaRow: some View {
        switch run.stravaUpload {
        case .notStarted, .uploading:
            HStack {
                Label("Uploading to Strava…", systemImage: "arrow.up.circle")
                Spacer()
                ProgressView()
            }
        case .uploaded:
            Label("Uploaded to Strava", systemImage: "checkmark.circle")
                .foregroundStyle(Brand.alert)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Strava upload failed", systemImage: "exclamationmark.circle")
                    .foregroundStyle(Brand.alert)
                Text(message).font(.brand(.caption)).foregroundStyle(.secondary)
                Button("Try again") { run.retryStravaUpload() }
            }
        case .off:
            EmptyView()
        }
    }

    @ViewBuilder private var uploadRow: some View {
        switch run.upload {
        case .notStarted, .uploading:
            HStack {
                Label("Uploading to Intervals…", systemImage: "icloud.and.arrow.up")
                Spacer()
                ProgressView()
            }
        case .uploaded:
            Label("Uploaded to Intervals", systemImage: "checkmark.icloud")
                .foregroundStyle(Brand.accent)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Upload failed", systemImage: "exclamationmark.icloud")
                    .foregroundStyle(Brand.alert)
                Text(message).font(.brand(.caption)).foregroundStyle(.secondary)
                Button("Try again") { run.retryUpload() }
            }
        case .off:
            Label("Saved on your phone (auto-upload is off). Upload it from Saved recordings.", systemImage: "icloud.slash")
                .foregroundStyle(.secondary)
        }
    }
}


/// The route's efforts on the live screen: the one under way (with its target and time in it), or
/// the next one and how far off it is.
struct EffortBanner: View {
    let player: RouteEffortPlayer
    let time: Double
    let ftp: Double?

    var body: some View {
        HStack(spacing: 10) {
            SuccessBar(width: 18, height: 7)
            if let active = player.active?.effort {
                Text(active.label.uppercased()).font(.hero(16)).akiraSlant()
                if let t = targetText(active) { Text(t).font(.num(.body)) }
                Spacer()
                Text(progressText(active)).font(.num(.body, weight: .semibold))
            } else if let next = player.upcoming {
                Text("\(next.effort.label) in \(Format.remainingDistance(next.distance))").bold()
                Spacer()
                if let t = targetText(next.effort) { Text(t).font(.num(.body)).foregroundStyle(.secondary) }
            } else {
                Text("No more efforts on this route").foregroundStyle(.secondary)
            }
        }
        .font(.brand(.headline))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Rectangle().fill(player.active != nil ? Brand.forest.opacity(0.16) : Color.secondary.opacity(0.12)))
        .accessibilityElement(children: .combine)
    }

    private func targetText(_ e: RouteEffort) -> String? {
        if let w = e.watts(ftp: ftp) { return Format.watts(w) }
        return e.targetText
    }

    /// Time left on a timed effort, else time in it.
    private func progressText(_ e: RouteEffort) -> String {
        guard let p = player.activeProgress(time: time) else { return "" }
        switch e.length {
        case .time(let s): return Format.clock(max(0, s - p.seconds).rounded(.up))
        case .distance(let d): return Format.remainingDistance(max(0, d - p.metres))
        case nil:
            if let stop = e.stop { return Format.remainingDistance(max(0, stop - e.start - p.metres)) }
            return Format.clock(p.seconds)
        }
    }
}

/// Live power for rides: 3 s watts, large, against the step's target band, with cadence.
struct PowerPanel: View {
    let watts: Int?
    let target: ClosedRange<Double>?
    let cadence: Int?
    let hasPower: Bool

    private enum Band { case under, inside, over }

    private var band: Band? {
        guard let watts, let target else { return nil }
        // A little slack either side so it doesn't flicker on the edge.
        let w = Double(watts)
        if w < target.lowerBound - 5 { return .under }
        if w > target.upperBound + 5 { return .over }
        return .inside
    }

    private var colour: Color {
        switch band {
        case .under: Brand.Medal.silver.flat
        case .inside: Brand.forest
        case .over: Brand.Medal.bronze.flat
        case nil: .primary
        }
    }

    var body: some View {
        Card(data: true) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .lastTextBaseline) {
                    if hasPower {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Power · 3 s").font(.brand(.caption)).foregroundStyle(.secondary)
                            Text(watts.map(String.init) ?? "––")
                                .font(.num(size: 58))
                                .foregroundStyle(colour)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Cadence").font(.brand(.caption)).foregroundStyle(.secondary)
                        Text(cadence.map(String.init) ?? "––")
                            .font(.num(size: hasPower ? 30 : 58))
                            .foregroundStyle(Brand.Data.cadence)
                    }
                }
                if hasPower, let target {
                    TargetBar(watts: watts, target: target, colour: colour)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}


/// Where the current watts sit against the step's target band, on a 0 to 2× target scale.
private struct TargetBar: View {
    let watts: Int?
    let target: ClosedRange<Double>
    let colour: Color

    var body: some View {
        let top = max(target.upperBound * 1.6, 1)
        VStack(spacing: 4) {
            GeometryReader { geo in
                let x: (Double) -> CGFloat = { CGFloat(min(max($0 / top, 0), 1)) * geo.size.width }
                ZStack(alignment: .leading) {
                    Rectangle().fill(Brand.Data.ink.opacity(0.06))
                    Rectangle().fill(Brand.forest.opacity(0.22))
                        .frame(width: max(x(target.upperBound) - x(target.lowerBound), 2))
                        .offset(x: x(target.lowerBound))
                    if let watts {
                        Rectangle().fill(colour).frame(width: 3)
                            .offset(x: x(Double(watts)) - 1.5)
                    }
                }
            }
            .frame(height: 14)
            HStack {
                Text("0")
                Spacer()
                Text("target " + Format.watts(target))
                Spacer()
                Text("\(Int(top))")
            }
            .font(.num(.caption2))
            .foregroundStyle(.secondary)
        }
    }
}

/// The live screen's buttons on the forest band.
struct FooterButton: ButtonStyle {
    enum Kind { case solid, outline, end }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.brand(.title3, weight: .semibold))
            .frame(maxWidth: kind == .solid ? .infinity : nil)
            .frame(minWidth: 96, minHeight: 56)
            .padding(.horizontal, 6)
            .foregroundStyle(kind == .solid ? Brand.forest : (kind == .end ? Color(hex: 0xE0A276) : .white))
            .background(kind == .solid ? Color.white : Color.clear)
            .overlay {
                if kind != .solid {
                    Rectangle().strokeBorder(kind == .end ? Color(hex: 0xC98552) : Color.white.opacity(0.7), lineWidth: 1.5)
                }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
