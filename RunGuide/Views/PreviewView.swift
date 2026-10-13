import SwiftUI
import CoreLocation
import RunGuideCore

struct PreviewView: View {
    let workout: Workout
    @ObservedObject var tracker: LocationTracker
    @EnvironmentObject private var settings: AppSettings
    @State private var running = false

    var body: some View {
        List {
            Section {
                gpsRow
            }

            if workout.steps.isEmpty {
                Section {
                    Text("Couldn't read any steps from this session. Check it's written in the Intervals workout format.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Steps") {
                    ForEach(workout.steps) { step in
                        HStack {
                            Text(step.label)
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text(Format.amount(step.end)).monospacedDigit()
                                if let target = step.target {
                                    Text(target).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(workout.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                running = true
            } label: {
                Text("Start")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .padding()
            .disabled(workout.steps.isEmpty || !authorised)
        }
        .onAppear { tracker.warmUp() }
        .fullScreenCover(isPresented: $running) {
            RunView(workout: workout, options: settings.engineOptions, tracker: tracker)
        }
    }

    private var authorised: Bool {
        tracker.authorization == .authorizedWhenInUse || tracker.authorization == .authorizedAlways
    }

    @ViewBuilder private var gpsRow: some View {
        if tracker.authorization == .denied || tracker.authorization == .restricted {
            Label("Location is off for Run Guide. Turn it on in Settings › Run Guide.", systemImage: "location.slash")
                .foregroundStyle(.red)
        } else if let accuracy = tracker.accuracy {
            let good = accuracy <= 15
            Label(good ? "GPS ready (±\(Int(accuracy)) m)" : "GPS settling (±\(Int(accuracy)) m)",
                  systemImage: good ? "location.fill" : "location")
                .foregroundStyle(good ? .green : .orange)
        } else {
            Label("Finding GPS…", systemImage: "location")
                .foregroundStyle(.secondary)
        }
    }
}
