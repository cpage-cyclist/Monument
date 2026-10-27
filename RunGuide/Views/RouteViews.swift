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
        return isLeft ? Brand.alert : Brand.accent
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
                        .font(.brand(.caption))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Circle().fill(.black))
                }
            }
            ForEach(Array(route.turns.enumerated()), id: \.offset) { index, turn in
                Annotation("", coordinate: turn.point.coordinate) {
                    Text("\(index + 1)")
                        .font(.brand(.caption2, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(turn.direction.colour))
                }
            }
        }
    }
}

/// A route's shape as a small line drawing: no map tiles, just the outline kept with the route.
struct RouteThumbnail: View {
    let outline: [GeoPoint]?
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Rectangle().fill(Brand.sky.opacity(0.6))
            if let outline, outline.count > 1 {
                RouteOutlineShape(points: RouteOutline.normalised(outline))
                    .stroke(Brand.wordmark, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .padding(size * 0.14)
            } else {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.system(size: size * 0.38))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .overlay { Rectangle().strokeBorder(Brand.hairline.opacity(0.35), lineWidth: 0.5) }
        .accessibilityHidden(true)
    }
}

/// Draws normalised (0...1) points into whatever square it's given.
struct RouteOutlineShape: Shape {
    let points: [(x: Double, y: Double)]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        let side = min(rect.width, rect.height)
        let ox = rect.midX - side / 2, oy = rect.midY - side / 2
        path.move(to: CGPoint(x: ox + first.x * side, y: oy + first.y * side))
        for p in points.dropFirst() {
            path.addLine(to: CGPoint(x: ox + p.x * side, y: oy + p.y * side))
        }
        return path
    }
}

struct RouteRow: View {
    let saved: SavedRoute

    var body: some View {
        HStack(spacing: 12) {
            RouteThumbnail(outline: saved.outline)
            VStack(alignment: .leading, spacing: 2) {
                Text(saved.name).lineLimit(1)
                Text(detail)
                    .font(.brand(.caption))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detail: String {
        var parts = [Format.km(saved.length)]
        if let sport = saved.sport { parts.append(sport.title) }
        if saved.isLoop { parts.append("loop") }
        parts.append("\(saved.turnCount) cues")
        return parts.joined(separator: " · ")
    }
}

struct RouteDetailView: View {
    let saved: SavedRoute
    var sport: RecordSport = .run
    @ObservedObject var tracker: LocationTracker
    @EnvironmentObject private var routes: RouteStore

    var body: some View {
        if let route = routes.route(for: saved) {
            BrandList {
                Section {
                    RouteMapView(route: route)
                        .frame(height: 320)
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    Text(route.name).font(.brand(.headline, weight: .semibold)).lineLimit(2)
                    LabeledContent("Distance", value: Format.km(route.length))
                    LabeledContent("Shape", value: route.isLoop ? "Loop (laps available)" : "Point to point")
                    NavigationLink {
                        PreviewView(workout: Workout(name: route.name, steps: [Step(id: 0, label: sport.title, end: .open, target: nil)]),
                                    sport: sport, tracker: tracker, initialRouteID: saved.id)
                    } label: {
                        Label("\(sport.title) this route", systemImage: sport.icon)
                    }
                }
                BrandSection("Cues") {
                    ForEach(Array(route.turns.enumerated()), id: \.offset) { index, turn in
                        HStack {
                            Text("\(index + 1)")
                                .font(.brand(.caption, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(turn.direction.colour))
                            Image(systemName: turn.direction.symbol)
                            Text(turn.label)
                            Spacer()
                            Text(Format.km(turn.at)).font(.num(.body)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .ridgeNavHeader("Route")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            Text("This route file couldn't be read.").foregroundStyle(.secondary)
        }
    }
}

/// Route choice on the session preview: the routes that suit the sport, most recent first.
struct RoutePickerSection: View {
    @Binding var routeID: UUID?
    @Binding var loop: Bool
    var sport: RecordSport = .run
    @EnvironmentObject private var routes: RouteStore

    private var choices: [SavedRoute] {
        routes.byRecency.filter { $0.suits(sport) || $0.id == routeID }
    }

    var body: some View {
        Section {
            Picker("Route", selection: $routeID) {
                Text("None").tag(UUID?.none)
                ForEach(choices) { saved in
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
                    .font(.brand(.caption))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Route")
        }
    }
}

/// Every route on the phone, searchable and filterable, with Strava and file import as the
/// ways to add more. Record only shows the last few.
struct RouteLibraryView: View {
    let sport: RecordSport
    @ObservedObject var tracker: LocationTracker
    @EnvironmentObject private var routes: RouteStore
    @State private var search = ""
    @State private var kind: RouteFilter
    @State private var importing = false
    @State private var renaming: SavedRoute?
    @State private var newName = ""

    init(sport: RecordSport, tracker: LocationTracker) {
        self.sport = sport
        self.tracker = tracker
        _kind = State(initialValue: sport == .ride ? .ride : .run)
    }

    private var shown: [SavedRoute] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return routes.byRecency.filter { saved in
            kind.includes(saved) && (query.isEmpty || saved.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        BrandList {
            Section {
                Picker("Show", selection: $kind) {
                    ForEach(RouteFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                NavigationLink {
                    StravaRoutesView(sport: sport)
                } label: {
                    Label("Add from Strava", systemImage: "arrow.down.circle")
                }
                Button { importing = true } label: {
                    Label("Import a GPX or TCX file", systemImage: "square.and.arrow.down")
                }
                if let error = routes.lastError {
                    Text(error).font(.brand(.footnote)).foregroundStyle(Brand.alert)
                }
            }
            BrandSection(shown.isEmpty ? "On this phone" : "On this phone · \(shown.count)") {
                if shown.isEmpty {
                    Text(routes.routes.isEmpty ? "No routes yet. Add some from Strava or import a file."
                                               : "Nothing matches.")
                        .foregroundStyle(.secondary)
                }
                ForEach(shown) { saved in
                    NavigationLink {
                        RouteDetailView(saved: saved, sport: sport, tracker: tracker)
                    } label: {
                        RouteRow(saved: saved)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { routes.delete(saved) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button { newName = saved.name; renaming = saved } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(Brand.sage)
                    }
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search routes")
        .ridgeNavHeader("Routes")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.gpx, .tcx, .xml]) { result in
            if case .success(let url) = result { routes.importRoute(from: url) }
        }
        .alert("Rename route", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let r = renaming { routes.rename(r, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

enum RouteFilter: String, CaseIterable, Identifiable {
    case run, ride, all

    var id: String { rawValue }
    var title: String {
        switch self {
        case .run: "Runs"
        case .ride: "Rides"
        case .all: "All"
        }
    }

    /// Files with no sport show under every filter.
    func includes(_ saved: SavedRoute) -> Bool {
        switch self {
        case .all: true
        case .run: saved.sport != .ride
        case .ride: saved.sport != .run
        }
    }

    func includes(_ strava: StravaRoute) -> Bool {
        switch self {
        case .all: true
        case .run: strava.sport == .run
        case .ride: strava.sport == .ride
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
                Image(systemName: next.turn.direction.symbol).font(.brand(.title2, weight: .bold))
                Text(next.turn.label).bold()
                Spacer()
                Text(Format.remainingDistance(next.distance)).font(.num(.body))
            } else {
                Image(systemName: "arrow.up")
                Text("Follow the route")
            }
            if guide.looping {
                Spacer(minLength: 0)
                Text("Lap \(guide.lap)").font(.brand(.caption, weight: .bold)).padding(.horizontal, 6)
                    .background(Capsule().fill(.quaternary))
            }
        }
        .font(.brand(.headline))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Rectangle().fill(guide.offRoute ? Brand.alert.opacity(0.25) : Color.secondary.opacity(0.12)))
    }
}
