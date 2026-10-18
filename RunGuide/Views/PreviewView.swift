import SwiftUI
import CoreLocation
import RunGuideCore

struct PreviewView: View {
    let workout: Workout
    @ObservedObject var tracker: LocationTracker
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var heartRate: HeartRateMonitor
    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var routes: RouteStore
    @EnvironmentObject private var strava: StravaAccount
    @State private var running = false
    @State private var routeID: UUID?
    @State private var loop = true

    init(workout: Workout, tracker: LocationTracker, initialRouteID: UUID? = nil) {
        self.workout = workout
        self.tracker = tracker
        _routeID = State(initialValue: initialRouteID)
    }

    private var selectedRoute: Route? {
        routes.routes.first { $0.id == routeID }.flatMap { routes.route(for: $0) }
    }

    var body: some View {
        List {
            Section {
                gpsRow
                if heartRate.hasPairedStrap {
                    hrRow
                }
            }

            RoutePickerSection(routeID: $routeID, loop: $loop)

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
        .onAppear {
            tracker.warmUp()
            heartRate.connect()
        }
        .fullScreenCover(isPresented: $running) {
            RunView(workout: workout,
                    options: settings.engineOptions,
                    tracker: tracker,
                    heartRate: heartRate,
                    store: store,
                    client: settings.autoUpload && settings.hasCredentials ? settings.client : nil,
                    route: selectedRoute,
                    loopRoute: loop,
                    strava: settings.uploadToStrava && strava.isConnected && strava.hasUploadAccess ? strava : nil)
        }
    }

    private var authorised: Bool {
        tracker.authorization == .authorizedWhenInUse || tracker.authorization == .authorizedAlways
    }

    @ViewBuilder private var hrRow: some View {
        if let bpm = heartRate.currentBPM {
            Label("\(heartRate.pairedName ?? "Strap") · \(bpm) bpm", systemImage: "heart.fill")
                .foregroundStyle(.red)
        } else {
            Label("Looking for \(heartRate.pairedName ?? "strap")… (put it on to wake it)", systemImage: "heart")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var gpsRow: some View {
        if tracker.authorization == .denied || tracker.authorization == .restricted {
            Label("Location is off for Monument. Turn it on in Settings › Monument.", systemImage: "location.slash")
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
