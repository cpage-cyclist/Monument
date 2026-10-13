import SwiftUI
import RunGuideCore

struct RunView: View {
    @StateObject private var run: RunController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmEnd = false

    init(workout: Workout, options: EngineOptions, tracker: LocationTracker) {
        _run = StateObject(wrappedValue: RunController(workout: workout, options: options, tracker: tracker))
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
            Text("Step \(min(engine.stepIndex + 1, engine.workout.steps.count)) of \(engine.workout.steps.count)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top)

            if let step = engine.currentStep {
                Text(step.label)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
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

            HStack {
                stat("Distance", Format.km(engine.totalDistance))
                stat("Time", Format.clock(engine.totalTime))
                stat("Pace", Format.pace(run.currentPace))
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
                }
                Section("Laps") {
                    ForEach(Array(run.engine.laps.enumerated()), id: \.offset) { _, lap in
                        HStack {
                            Text(lap.label)
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text("\(Format.km(lap.distance)) · \(Format.clock(lap.duration))")
                                    .monospacedDigit()
                                Text("\(Format.pace(lap.pace))/km")
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: done)
                }
            }
        }
    }
}
