import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var heartRate: HeartRateMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var announcer = Announcer()

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
                    Toggle("Upload runs automatically", isOn: $settings.autoUpload)
                } header: {
                    Text("Intervals.icu")
                } footer: {
                    Text("Both are on intervals.icu under Settings › Developer Settings. The key is stored in this phone's Keychain.")
                }

                heartRateSection

                Section {
                    Toggle("Say pace at the end of each step", isOn: $settings.lapPaceFeedback)
                    Toggle("Km splits on long steps", isOn: $settings.kmSplits)
                    Button("Test voice") {
                        announcer.speak("Rep 1 of 5. 1 kilometre at 4 minutes per kilometre.")
                    }
                    LabeledContent("Voice", value: Announcer.voiceDescription)
                } header: {
                    Text("Voice")
                } footer: {
                    Text("For a more natural voice, download a Premium or Enhanced UK voice in iPhone Settings › Accessibility › Spoken Content › Voices › English › English (UK). Run Guide picks the best one automatically.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                Button("Done") { dismiss() }
            }
            .onDisappear { heartRate.stopScan() }
        }
    }

    @ViewBuilder private var heartRateSection: some View {
        Section {
            if let name = heartRate.pairedName {
                HStack {
                    Label(name, systemImage: "heart.fill").foregroundStyle(.red)
                    Spacer()
                    if let bpm = heartRate.currentBPM {
                        Text("\(bpm) bpm").monospacedDigit()
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
                Text("Bluetooth is off or not allowed for Run Guide.")
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
