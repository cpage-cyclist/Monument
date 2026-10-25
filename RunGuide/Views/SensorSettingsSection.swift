import SwiftUI

/// Pairing for a power meter or cadence sensor, in Settings. Same flow as the heart-rate strap.
struct SensorSettingsSection: View {
    @ObservedObject var sensor: CyclingSensor

    private var isPower: Bool { sensor.role == .power }

    var body: some View {
        Section {
            if let name = sensor.pairedName {
                HStack {
                    Label(name, systemImage: isPower ? "bolt.fill" : "arrow.triangle.2.circlepath")
                    Spacer()
                    Text(reading).monospacedDigit().foregroundStyle(.secondary)
                }
                Button("Connect now") { sensor.connect() }
                Button(isPower ? "Forget power meter" : "Forget cadence sensor", role: .destructive) { sensor.forget() }
            } else if sensor.state == .scanning {
                HStack {
                    Text(isPower ? "Searching… spin the cranks to wake it" : "Searching… turn the cranks to wake it")
                    Spacer()
                    ProgressView()
                }
                ForEach(sensor.found) { device in
                    Button(device.name) { sensor.pair(device) }
                }
                Button("Stop searching") { sensor.stopScan() }
            } else if sensor.state == .off {
                Text("Bluetooth is off or not allowed for Monument.").foregroundStyle(.secondary)
            } else {
                Button(isPower ? "Pair a power meter" : "Pair a cadence sensor") { sensor.startScan() }
            }
        } header: {
            Text(isPower ? "Power meter" : "Cadence sensor")
        } footer: {
            Text(isPower
                 ? "Any Bluetooth power meter. Power (and cadence, if it sends it) is shown on rides and saved in the FIT file."
                 : "Only needed if your power meter doesn't send cadence, or for rides without one.")
        }
        .onDisappear { sensor.stopScan() }
    }

    private var reading: String {
        if isPower, let w = sensor.currentWatts {
            return sensor.currentCadence.map { "\(w) W · \($0) rpm" } ?? "\(w) W"
        }
        if let c = sensor.currentCadence { return "\(c) rpm" }
        return sensor.state == .connecting ? "Connecting…" : (sensor.state == .connected ? "Connected" : "Not connected")
    }
}
