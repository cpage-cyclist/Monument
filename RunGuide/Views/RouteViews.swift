import MapKit
import SwiftUI
import RunGuideCore

extension GeoPoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

extension TurnDirection {
    var symbol: String {
        switch self {
        case .bearLeft: return "arrow.up.left"
        case .left: return "arrow.turn.up.left"
        case .sharpLeft: return "arrow.down.left"
        case .bearRight: return "arrow.up.right"
        case .right: return "arrow.turn.up.right"
        case .sharpRight: return "arrow.down.right"
        case .turnAround: return "arrow.uturn.down"
        case .straight: return "arrow.up"
        }
    }

    var colour: Color {
        if self == .straight { return .gray }
        return isLeft ? .orange : .green
    }
}

extension RouteTurn {
    var label: String {
        let text = tricky ? "Tricky junction, \(direction.phrase)" : direction.phrase
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// The route line with a numbered marker at each cue.
struct RouteMapView: View {
    let route: Route

    var body: some View {
        Map(initialPosition: .automatic) {
            MapPolyline(coordinates: route.points.map(\.coordinate))
                .stroke(.blue, lineWidth: 4)
            if let start = route.points.first {
                Annotation("Start", coordinate: start.coordinate) {
                    Image(systemName: "flag.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Circle().fill(.black))
                }
            }
            ForEach(Array(route.turns.enumerated()), id: \.offset) { index, turn in
                Annotation("", coordinate: turn.point.coordinate) {
                    Text("\(index + 1)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(turn.direction.colour))
                }
            }
        }
    }
}

struct RouteRow: View {
    let saved: SavedRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(saved.name)
            Text("\(Format.km(saved.length)) · \(saved.turnCount) cues\(saved.isLoop ? " · loop" : "")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct RouteDetailView: View {
    let saved: SavedRoute
    @ObservedObject var tracker: LocationTracker
    @EnvironmentObject private var routes: RouteStore

    var body: some View {
        if let route = routes.route(for: saved) {
            List {
                Section {
                    RouteMapView(route: route)
                        .frame(height: 320)
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    LabeledContent("Distance", value: Format.km(route.length))
                    LabeledContent("Shape", value: route.isLoop ? "Loop (laps available)" : "Point to point")
                    NavigationLink {
                        PreviewView(workout: .freeRun(name: route.name), tracker: tracker, initialRouteID: saved.id)
                    } label: {
                        Label("Run this route", systemImage: "figure.run")
                    }
                }
                Section("Cues") {
                    ForEach(Array(route.turns.enumerated()), id: \.offset) { index, turn in
                        HStack {
                            Text("\(index + 1)")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(turn.direction.colour))
                            Image(systemName: turn.direction.symbol)
                            Text(turn.label)
                            Spacer()
                            Text(Format.km(turn.at)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(route.name)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            Text("This route file couldn't be read.").foregroundStyle(.secondary)
        }
    }
}

/// Route choice on the session preview.
struct RoutePickerSection: View {
    @Binding var routeID: UUID?
    @Binding var loop: Bool
    @EnvironmentObject private var routes: RouteStore

    var body: some View {
        Section {
            Picker("Route", selection: $routeID) {
                Text("None").tag(UUID?.none)
                ForEach(routes.routes) { saved in
                    Text(saved.name).tag(Optional(saved.id))
                }
            }
            if let saved = routes.routes.first(where: { $0.id == routeID }),
               let route = routes.route(for: saved) {
                RouteMapView(route: route)
                    .frame(height: 200)
                    .listRowInsets(EdgeInsets())
                if route.isLoop {
                    Toggle("Repeat laps", isOn: $loop)
                }
                Text("\(Format.km(route.length)) · \(route.turns.count) cues. Turn cues cut in over session cues.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Route")
        }
    }
}

/// Next turn / off-route / lap banner on the run screen.
struct RouteBanner: View {
    let guide: RouteGuide

    var body: some View {
        HStack(spacing: 10) {
            if guide.offRoute {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Off route").bold()
            } else if guide.finished {
                Image(systemName: "flag.checkered")
                Text("End of route")
            } else if guide.progress == nil {
                Image(systemName: "location.magnifyingglass")
                Text("Finding the route…")
            } else if let next = guide.nextTurn {
                Image(systemName: next.turn.direction.symbol).font(.title2.bold())
                Text(next.turn.label).bold()
                Spacer()
                Text(Format.remainingDistance(next.distance)).monospacedDigit()
            } else {
                Image(systemName: "arrow.up")
                Text("Follow the route")
            }
            if guide.looping {
                Spacer(minLength: 0)
                Text("Lap \(guide.lap)").font(.caption.bold()).padding(.horizontal, 6)
                    .background(Capsule().fill(.quaternary))
            }
        }
        .font(.headline)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(guide.offRoute ? Color.red.opacity(0.25) : Color.secondary.opacity(0.12)))
    }
}
