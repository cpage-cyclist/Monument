import AuthenticationServices
import SwiftUI
import RunGuideCore

/// Settings section: your Strava API app details and the connection.
struct StravaSettingsSection: View {
    @EnvironmentObject private var strava: StravaAccount
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
                Button("Disconnect", role: .destructive) { strava.disconnect() }
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

/// Your saved Strava routes; tap one to import it.
struct StravaRoutesView: View {
    @EnvironmentObject private var strava: StravaAccount
    @EnvironmentObject private var routes: RouteStore

    @State private var list: [StravaRoute] = []
    @State private var loading = false
    @State private var importing: String?
    @State private var errorText: String?
    @State private var showRunsOnly = true

    private var shown: [StravaRoute] {
        showRunsOnly ? list.filter(\.isRun) : list
    }

    var body: some View {
        BrandList {
            if !strava.isConnected {
                Text("Connect Strava in Settings (gear icon on the home screen) to see your routes here.")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    Toggle("Running routes only", isOn: $showRunsOnly)
                    if let errorText {
                        Text(errorText).font(.brand(.footnote)).foregroundStyle(Brand.alert)
                    }
                    if loading && list.isEmpty {
                        HStack { Text("Loading your routes…"); Spacer(); ProgressView() }
                    } else if !loading && shown.isEmpty {
                        Text(list.isEmpty ? "No saved routes found on Strava." : "No running routes. Turn off the filter to see rides.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach(shown) { route in
                        Button {
                            Task { await importRoute(route) }
                        } label: {
                            HStack {
                                Image(systemName: route.isRun ? "figure.run" : "bicycle")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(route.name).foregroundStyle(.primary)
                                    Text(Format.km(route.distance) + (route.isPrivate == true ? " · private" : ""))
                                        .font(.brand(.caption))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if importing == route.id {
                                    ProgressView()
                                } else if routes.routes.contains(where: { $0.stravaID == route.id }) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.accent)
                                } else {
                                    Image(systemName: "square.and.arrow.down").foregroundStyle(.tint)
                                }
                            }
                        }
                        .disabled(importing != nil)
                    }
                } footer: {
                    if !shown.isEmpty {
                        Text("Tap a route to import it (tap again to refresh it after editing in Strava).")
                    }
                }
            }
        }
        .ridgeNavHeader("Routes")
        .refreshable { await load() }
        .task { if list.isEmpty { await load() } }
    }

    private func load() async {
        guard strava.isConnected else { return }
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            list = try await strava.routes()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func importRoute(_ route: StravaRoute) async {
        importing = route.id
        errorText = nil
        defer { importing = nil }
        do {
            let data = try await strava.gpx(for: route)
            if routes.importRoute(data: data, fallbackName: route.name, stravaID: route.id) == nil {
                errorText = routes.lastError ?? "Couldn't read that route."
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
