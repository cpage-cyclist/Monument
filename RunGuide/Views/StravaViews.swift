import AuthenticationServices
import SwiftUI
import UIKit
import RunGuideCore

/// Settings section: your Strava API app details and the connection.
struct StravaSettingsSection: View {
    @EnvironmentObject private var strava: StravaAccount
    @EnvironmentObject private var routes: RouteStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.webAuthenticationSession) private var webAuth

    var body: some View {
        Section {
            TextField("Client ID", text: $strava.clientID)
                .keyboardType(.numberPad)
            SecureField("Client Secret", text: $strava.clientSecret)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if strava.isConnected {
                LabeledContent("Connected", value: strava.athleteName?.isEmpty == false ? strava.athleteName! : "Yes")
                Toggle("Upload runs to Strava", isOn: $settings.uploadToStrava)
                if settings.uploadToStrava && !strava.hasUploadAccess {
                    Text("Tap Reconnect and leave \"Upload your activities\" ticked to allow uploads.")
                        .font(.brand(.footnote))
                        .foregroundStyle(Brand.alert)
                }
                if !strava.hasPrivateAccess {
                    Text("Private routes aren't included. Reconnect and leave private access ticked.")
                        .font(.brand(.footnote))
                        .foregroundStyle(Brand.alert)
                }
                Button("Reconnect") { Task { await strava.connect(using: webAuth) } }
                Button("Disconnect", role: .destructive) {
                    strava.disconnect()
                    routes.clearStravaList()
                }
            } else {
                Button {
                    Task { await strava.connect(using: webAuth) }
                } label: {
                    HStack {
                        Text("Connect Strava")
                        if strava.connecting { Spacer(); ProgressView() }
                    }
                }
                .disabled(!strava.hasAppDetails)
            }

            if let error = strava.lastError {
                Text(error).font(.brand(.footnote)).foregroundStyle(Brand.alert)
            }
        } header: {
            Text("Strava")
        } footer: {
            Text("One-off setup: on strava.com go to Settings › My API Application, create an app (any name and website) with Authorization Callback Domain set to localhost, then paste its Client ID and Client Secret here. The secret is kept in this phone's Keychain.")
        }
    }
}

/// Your saved Strava routes; tap one to import it. The list opens from the last copy on the
/// phone and only goes back to Strava when that's stale or you pull down.
struct StravaRoutesView: View {
    let sport: RecordSport
    @EnvironmentObject private var strava: StravaAccount
    @EnvironmentObject private var routes: RouteStore

    @State private var importing: String?
    @State private var errorText: String?
    @State private var kind: RouteFilter

    init(sport: RecordSport = .run) {
        self.sport = sport
        _kind = State(initialValue: sport == .ride ? .ride : .run)
    }
    @State private var search = ""

    private var shown: [StravaRoute] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return routes.stravaRoutes.filter {
            kind.includes($0) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        BrandList {
            if !strava.isConnected {
                Text("Connect Strava in Settings to see your routes here.")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    Picker("Show", selection: $kind) {
                        ForEach(RouteFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if let message = errorText ?? routes.stravaError {
                        Text(message).font(.brand(.footnote)).foregroundStyle(Brand.alert)
                    }
                    if routes.stravaLoading && routes.stravaRoutes.isEmpty {
                        HStack { Text("Loading your routes…"); Spacer(); ProgressView() }
                    } else if shown.isEmpty, !routes.stravaLoading {
                        Text(routes.stravaRoutes.isEmpty ? "No saved routes found on Strava." : "Nothing matches.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach(shown) { route in
                        Button {
                            Task { await importRoute(route) }
                        } label: {
                            row(route)
                        }
                        .disabled(importing != nil)
                    }
                } footer: {
                    if !shown.isEmpty { footer }
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search Strava routes")
        .ridgeNavHeader("Strava")
        .refreshable { await routes.refreshStravaRoutes(using: strava, force: true) }
        .task { await routes.refreshStravaRoutes(using: strava) }
    }

    private func row(_ route: StravaRoute) -> some View {
        let saved = routes.saved(forStrava: route.id)
        let outdated = routes.isOutdated(route)
        return HStack(spacing: 12) {
            RouteThumbnail(outline: routes.stravaOutlines[route.id])
            VStack(alignment: .leading, spacing: 2) {
                Text(route.name).foregroundStyle(.primary).lineLimit(1)
                Text(detail(route, outdated: outdated))
                    .font(.brand(.caption))
                    .foregroundStyle(outdated ? AnyShapeStyle(Brand.alert) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 8)
            if importing == route.id {
                ProgressView()
            } else if outdated {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Brand.alert)
                    .accessibilityLabel("Changed on Strava, tap to update")
            } else if saved != nil {
                SuccessBar(width: 18, height: 7)
                    .accessibilityLabel("On this phone")
            } else {
                Image(systemName: "square.and.arrow.down").foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }

    private func detail(_ route: StravaRoute, outdated: Bool) -> String {
        var parts = [Format.km(route.distance)]
        if let gain = route.elevationGain, gain >= 1 { parts.append("\(Int(gain.rounded())) m up") }
        if route.isPrivate == true { parts.append("private") }
        if outdated { parts.append("changed on Strava") }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tap a route to put it on the phone; tap again to refresh it after editing on Strava.")
            if let fetched = routes.stravaFetchedAt {
                Text("List updated \(fetched.formatted(.relative(presentation: .named))). Pull down to check Strava again.")
            }
        }
    }

    private func importRoute(_ route: StravaRoute) async {
        importing = route.id
        errorText = nil
        defer { importing = nil }
        do {
            let data = try await strava.gpx(for: route)
            // Waypoints (efforts) come from the route's details; a failure here just means none.
            let waypoints = try? await strava.waypoints(for: route)
            if routes.importRoute(data: data, fallbackName: route.name, strava: route, waypoints: waypoints) == nil {
                errorText = routes.lastError ?? "Couldn't read that route."
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
