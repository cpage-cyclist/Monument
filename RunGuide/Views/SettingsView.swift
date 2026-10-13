import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
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
                } header: {
                    Text("Intervals.icu")
                } footer: {
                    Text("Both are on intervals.icu under Settings › Developer Settings. The key is stored in this phone's Keychain.")
                }

                Section {
                    Toggle("Say pace at the end of each step", isOn: $settings.lapPaceFeedback)
                    Toggle("Km splits on long steps", isOn: $settings.kmSplits)
                    Button("Test voice") {
                        announcer.speak("Rep 1 of 5. 1 kilometre at 4 minutes per kilometre.")
                    }
                } header: {
                    Text("Voice")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
    }
}
