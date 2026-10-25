import SwiftUI
import RunGuideCore

struct RunView: View {
    @StateObject private var run: RunController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmEnd = false

    init(workout: Workout, sport: RecordSport, options: EngineOptions, tracker: LocationTracker,
         heartRate: HeartRateMonitor, power: CyclingSensor? = nil, cadence: CyclingSensor? = nil,
         store: RunStore, client: IntervalsClient?,
         route: Route? = nil, loopRoute: Bool = false, strava: StravaAccount? = nil) {
        _run = StateObject(wrappedValue: RunController(workout: workout, sport: sport, options: options,
                                                       tracker: tracker, heartRate: heartRate,
                                                       power: power, cadence: cadence,
                                                       store: store, client: client,
                                                       route: route, loopRoute: loopRoute, strava: strava))
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

    private var live: some View {
        VStack(spacing: 18) {
            if let guide = run.guide {
                RouteBanner(guide: guide)
                    .padding(.top)
                    .id(run.tick)
            }

            Group {
                if engine.isFree {
                    Label("\(run.sport.title) · lap \(engine.laps.count + 1)", systemImage: run.sport.icon)
                } else {
                    Text("\(run.sport.title) · step \(min(engine.stepIndex + 1, engine.workout.steps.count)) of \(engine.workout.steps.count)")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, run.guide == nil ? 16 : 0)

            if let step = engine.currentStep {
                if !engine.isFree {
                    Text(step.label)
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                }
                if let target = step.target {
                    Text(target).font(.title3).foregroundStyle(.secondary)
                }

                Text(remainingText(step))
                    .font(.system(size: 76, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)

                ProgressView(value: engine.stepProgress)
                    .padding(.horizontal)
            }

            if let next = engine.nextStep {
                Text("Next: \(next.label) · \(Format.amount(next.end))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if run.hasPowerSensors {
                PowerPanel(watts: run.power?.threeSecondWatts, target: engine.currentStep?.watts,
                           cadence: run.currentCadence, hasPower: run.power != nil)
            }

            HStack {
                stat("Distance", Format.km(engine.totalDistance))
                stat("Time", Format.clock(engine.totalTime))
                if run.sport.usesPace {
                    stat("Pace", Format.pace(run.currentPace))
                } else {
                    stat("km/h", run.currentSpeed.map { String(format: "%.1f", $0) } ?? "––")
                }
                if run.heartRate.hasPairedStrap {
                    stat("HR", run.heartRate.currentBPM.map(String.init) ?? "––")
                }
            }
            .padding(.top, 8)

            if run.paused {
                Text("PAUSED").font(.headline).foregroundStyle(.orange)
            }

            Spacer()

            HStack(spacing: 12) {
                Button(run.paused ? "Resume" : "Pause") { run.togglePause() }
                    .buttonStyle(.bordered)
                Button("Lap") { run.lap() }
                    .buttonStyle(.borderedProminent)
                Button("End", role: .destructive) { confirmEnd = true }
                    .buttonStyle(.bordered)
            }
            .font(.title3.bold())
            .controlSize(.large)
            .padding(.bottom)
        }
        .padding(.horizontal)
        .confirmationDialog("End the session now?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End session", role: .destructive) { run.end() }
            Button("Keep going", role: .cancel) {}
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
        VStack(spacing: 2) {
            Text(value).font(.title3.bold()).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct SummaryView: View {
    @ObservedObject var run: RunController
    let done: () -> Void
    @State private var confirmDiscard = false

    var body: some View {
        NavigationStack {
            List {
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
                            .foregroundStyle(.red)
                    }
                }
                Section("Laps") {
                    ForEach(Array(run.engine.laps.enumerated()), id: \.offset) { _, lap in
                        HStack {
                            Text(lap.label)
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text("\(Format.km(lap.distance)) · \(Format.clock(lap.duration))")
                                    .monospacedDigit()
                                Text(run.sport.usesPace ? "\(Format.pace(lap.pace))/km"
                                                        : lap.pace.map { String(format: "%.1f km/h", 3600 / $0) } ?? "–")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Session done")
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
                                .font(.headline)
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
                .foregroundStyle(.orange)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Strava upload failed", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                Text(message).font(.caption).foregroundStyle(.secondary)
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
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Upload failed", systemImage: "exclamationmark.icloud")
                    .foregroundStyle(.red)
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("Try again") { run.retryUpload() }
            }
        case .off:
            Label("Saved on your phone (auto-upload is off). Upload it from Saved recordings.", systemImage: "icloud.slash")
                .foregroundStyle(.secondary)
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
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            if hasPower {
                VStack(spacing: 2) {
                    Text(watts.map(String.init) ?? "––")
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(colour)
                    Text(target.map { "W · target " + Format.watts($0) } ?? "W (3 s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 2) {
                Text(cadence.map(String.init) ?? "––")
                    .font(.system(size: hasPower ? 30 : 54, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("rpm").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background {
            if let band {
                RoundedRectangle(cornerRadius: 14)
                    .fill(colour.opacity(band == .inside ? 0.12 : 0.18))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
