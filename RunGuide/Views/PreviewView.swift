import SwiftUI
import CoreLocation
import RunGuideCore

/// The last screen before starting: sensors, an optional route, the steps, and Start. The sport
/// is fixed from here on.
struct PreviewView: View {
    let workout: Workout
    let sport: RecordSport
    @ObservedObject var tracker: LocationTracker
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var heartRate: HeartRateMonitor
    @EnvironmentObject private var sensors: CyclingSensors
    @EnvironmentObject private var store: RunStore
    @EnvironmentObject private var routes: RouteStore
    @EnvironmentObject private var strava: StravaAccount
    @EnvironmentObject private var rider: RiderStore
    @EnvironmentObject private var library: ActivityLibrary
    @State private var running = false
    @State private var routeID: UUID?
    @State private var loop = true

    init(workout: Workout, sport: RecordSport, tracker: LocationTracker, initialRouteID: UUID? = nil) {
        self.workout = workout
        self.sport = sport
        self.tracker = tracker
        _routeID = State(initialValue: initialRouteID)
    }

    private var selectedRoute: Route? {
        routes.routes.first { $0.id == routeID }.flatMap { routes.route(for: $0) }
    }

    /// The selected route's efforts, which play when this is a free recording.
    private var routeEfforts: [RouteEffort] {
        guard workout.steps.count == 1, workout.steps[0].end == .open, workout.steps[0].target == nil,
              let saved = routes.routes.first(where: { $0.id == routeID }) else { return [] }
        return routes.efforts(for: saved)
    }

    var body: some View {
        BrandList {
            Section {
                Text(workout.name)
                    .font(.brand(.headline, weight: .semibold))
                    .lineLimit(2)
                Label("\(sport.title) · locked for this recording", systemImage: sport.icon)
                    .font(.brand(.subheadline, weight: .medium))
                SensorStatus(sport: sport, tracker: tracker, power: sensors.power, cadence: sensors.cadence)
            }

            RoutePickerSection(routeID: $routeID, loop: $loop, sport: sport)

            if workout.steps.isEmpty {
                Section {
                    Text("Couldn't read any steps from this session. Check it's written in the Intervals workout format.")
                        .foregroundStyle(.secondary)
                }
            } else {
                BrandSection("Steps") {
                    ForEach(workout.steps) { step in
                        HStack {
                            Text(step.label)
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text(Format.amount(step.end)).font(.num(.body))
                                if let target = step.target {
                                    Text(target).font(.brand(.caption)).foregroundStyle(.secondary)
                                }
                                if let w = step.watts {
                                    Text(Format.watts(w)).font(.num(.caption)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .ridgeNavHeader(sport.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                if let routeID { routes.markUsed(routeID) }
                running = true
            } label: {
                Text("Start")
                    .font(.brand(.title2, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .padding()
            .disabled(workout.steps.isEmpty || !authorised)
        }

        .fullScreenCover(isPresented: $running) {
            RunView(workout: workout,
                    sport: sport,
                    options: settings.engineOptions,
                    tracker: tracker,
                    heartRate: heartRate,
                    power: sensors.power,
                    cadence: sensors.cadence,
                    store: store,
                    client: settings.autoUpload && settings.hasCredentials ? settings.client : nil,
                    route: selectedRoute,
                    loopRoute: loop,
                    strava: settings.uploadToStrava && strava.isConnected && strava.hasUploadAccess ? strava : nil,
                    efforts: routeEfforts,
                    ftp: rider.ftp(settings.thresholdSource, intervalsFallback: library.latestFTP),
                    effortFeedback: settings.effortFeedback)
        }
    }

    private var authorised: Bool {
        tracker.authorization == .authorizedWhenInUse || tracker.authorization == .authorizedAlways
    }
}
