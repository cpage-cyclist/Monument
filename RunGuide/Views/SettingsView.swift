import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var heartRate: HeartRateMonitor
    @EnvironmentObject private var sensors: CyclingSensors
    @EnvironmentObject private var rider: RiderStore
    @EnvironmentObject private var library: ActivityLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var announcer = Announcer()
    @State private var voices = Announcer.englishVoices

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Athlete ID, e.g. i123456", text: $settings.athleteId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API key", text: $settings.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Upload recordings automatically", isOn: $settings.autoUpload)
                } header: {
                    Text("Intervals.icu")
                } footer: {
                    Text("Both are on intervals.icu under Settings › Developer Settings. The key is stored in this phone's Keychain.")
                }

                StravaSettingsSection()

                Section {
                    Picker("Thresholds from", selection: $settings.thresholdSource) {
                        ForEach(ThresholdSource.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Intervals FTP",
                                   value: rider.ftp(.intervals, intervalsFallback: library.latestFTP)
                                       .map { "\(Int($0.rounded())) W" } ?? "–")
                    LabeledContent("Monument FTP",
                                   value: rider.monument.map { "\(Int($0.ftp.rounded())) W" } ?? "Not enough efforts yet")
                    if let m = rider.monument {
                        LabeledContent("Monument CP · W′",
                                       value: "\(Int(m.cp.rounded())) W · " + String(format: "%.1f kJ", m.wPrime / 1000))
                    }
                } header: {
                    Text("Power profile")
                } footer: {
                    Text("Monument fits the omni-domain power-duration model (Puchowicz et al. 2020) to your best efforts over the last 90 days; its FTP is the modelled one-hour power. The choice sets workout target watts, the Rider card and the W′bal chart's default.")
                }

                heartRateSection
                SensorSettingsSection(sensor: sensors.power)
                SensorSettingsSection(sensor: sensors.cadence)

                Section {
                    Toggle("Say pace (or speed on rides) at the end of each step", isOn: $settings.lapPaceFeedback)
                    Toggle("Splits on long steps (every km, or 5 km on rides)", isOn: $settings.kmSplits)
                    Picker("Voice", selection: $settings.voiceIdentifier) {
                        Text("Automatic (best UK voice)").tag("")
                        ForEach(voices, id: \.identifier) { voice in
                            Text(Announcer.label(for: voice)).tag(voice.identifier)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Button("Test voice") {
                        announcer.stopAll()
                        announcer.speak("Rep 1 of 5. 1 kilometre at 4 minutes per kilometre.")
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    Text("For a more natural voice, download a Premium or Enhanced UK voice in iPhone Settings › Accessibility › Spoken Content › Voices › English › English (UK). New voices appear here once downloaded.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                Button("Done") { dismiss() }
            }
            .onDisappear { heartRate.stopScan() }
            .onAppear { voices = Announcer.englishVoices }
        }
    }

    @ViewBuilder private var heartRateSection: some View {
        Section {
            if let name = heartRate.pairedName {
                HStack {
                    Label(name, systemImage: "heart.fill").foregroundStyle(.red)
                    Spacer()
                    if let bpm = heartRate.currentBPM {
                        Text("\(bpm) bpm").font(.num(.body))
                    } else {
                        Text(heartRate.state == .connecting ? "Connecting…" : "Not connected")
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Connect now") { heartRate.connect() }
                Button("Forget strap", role: .destructive) { heartRate.forget() }
            } else if heartRate.state == .scanning {
                HStack {
                    Text("Searching… put the strap on to wake it")
                    Spacer()
                    ProgressView()
                }
                ForEach(heartRate.found) { device in
                    Button(device.name) { heartRate.pair(device) }
                }
                Button("Stop searching") { heartRate.stopScan() }
            } else if heartRate.state == .off {
                Text("Bluetooth is off or not allowed for Monument.")
                    .foregroundStyle(.secondary)
            } else {
                Button("Pair a heart-rate strap") { heartRate.startScan() }
            }
        } header: {
            Text("Heart rate")
        } footer: {
            Text("Works with any Bluetooth chest strap. Heart rate is saved in the FIT file and shown while you run.")
        }
    }
}
