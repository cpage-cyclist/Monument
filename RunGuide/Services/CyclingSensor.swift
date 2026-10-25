import CoreBluetooth
import Foundation
import RunGuideCore

/// A Bluetooth power meter (Cycling Power, service 0x1818) or cadence sensor (Cycling Speed and
/// Cadence, service 0x1816). Works like the heart-rate strap: pair once, then it reconnects by
/// itself. A power meter that sends crank data gives cadence too.
final class CyclingSensor: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    enum Role: String {
        case power, cadence

        var service: CBUUID { CBUUID(string: self == .power ? "1818" : "1816") }
        var measurement: CBUUID { CBUUID(string: self == .power ? "2A63" : "2A5B") }
        var defaultName: String { self == .power ? "Power meter" : "Cadence sensor" }
    }

    struct Found: Identifiable, Hashable {
        let id: UUID
        let name: String
    }

    enum State: Equatable {
        case off, idle, scanning, connecting, connected
    }

    let role: Role

    /// Latest instantaneous power (power meters only).
    @Published private(set) var watts: Int?
    @Published private(set) var cadence: Int?
    @Published private(set) var state: State = .idle
    @Published private(set) var found: [Found] = []
    @Published private(set) var pairedName: String?

    private var pairedKey: String { "pairedSensor.\(role.rawValue)" }
    private var pairedNameKey: String { "pairedSensorName.\(role.rawValue)" }

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var seen: [UUID: CBPeripheral] = [:]
    private var wantConnection = false
    private var wantScan = false
    private var lastPower: Date?
    private var lastCadence: Date?
    private var cadenceCalc = CadenceCalculator()
    private var smoothed = RollingAverage(seconds: 3)

    init(role: Role) {
        self.role = role
        super.init()
        pairedName = UserDefaults.standard.string(forKey: pairedNameKey)
    }

    var isPaired: Bool { pairedID != nil }

    private var pairedID: UUID? {
        UserDefaults.standard.string(forKey: pairedKey).flatMap(UUID.init(uuidString:))
    }

    /// Readings older than 4 s count as none (sensor asleep or out of range).
    var currentWatts: Int? {
        guard let watts, let lastPower, Date().timeIntervalSince(lastPower) < 4 else { return nil }
        return watts
    }

    /// Power averaged over the last 3 s, for the screen.
    var threeSecondWatts: Int? {
        guard currentWatts != nil, let v = smoothed.value(at: Date()) else { return nil }
        return Int(v.rounded())
    }

    var currentCadence: Int? {
        guard let cadence, let lastCadence, Date().timeIntervalSince(lastCadence) < 4 else { return nil }
        return cadence
    }

    // MARK: - Public actions

    func startScan() {
        found = []
        wantScan = true
        ensureCentral()
        guard central?.state == .poweredOn else { return }
        state = .scanning
        central?.scanForPeripherals(withServices: [role.service])
    }

    func stopScan() {
        wantScan = false
        central?.stopScan()
        if state == .scanning { state = peripheral?.state == .connected ? .connected : .idle }
    }

    func pair(_ device: Found) {
        UserDefaults.standard.set(device.id.uuidString, forKey: pairedKey)
        UserDefaults.standard.set(device.name, forKey: pairedNameKey)
        pairedName = device.name
        stopScan()
        connect()
    }

    func forget() {
        disconnect()
        UserDefaults.standard.removeObject(forKey: pairedKey)
        UserDefaults.standard.removeObject(forKey: pairedNameKey)
        pairedName = nil
    }

    func connect() {
        guard pairedID != nil else { return }
        wantConnection = true
        ensureCentral()
        tryConnect()
    }

    func disconnect() {
        wantConnection = false
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        watts = nil
        cadence = nil
        state = .idle
    }

    // MARK: - Internals

    private func ensureCentral() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: true])
        }
    }

    private func tryConnect() {
        guard wantConnection, let central, central.state == .poweredOn, let id = pairedID else { return }
        if let known = central.retrievePeripherals(withIdentifiers: [id]).first ?? seen[id] {
            peripheral = known
            known.delegate = self
            state = .connecting
            central.connect(known)
        } else {
            state = .connecting
            central.scanForPeripherals(withServices: [role.service])
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            if state == .off { state = .idle }
            if wantScan {
                state = .scanning
                central.scanForPeripherals(withServices: [role.service])
            }
            tryConnect()
        } else {
            state = .off
            watts = nil
            cadence = nil
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        seen[peripheral.identifier] = peripheral
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? role.defaultName
        if !found.contains(where: { $0.id == peripheral.identifier }) {
            found.append(Found(id: peripheral.identifier, name: name))
        }
        if wantConnection, peripheral.identifier == pairedID, self.peripheral == nil || state == .connecting {
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .connected
        cadenceCalc = CadenceCalculator()
        peripheral.discoverServices([role.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .idle
        retrySoon()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        watts = nil
        cadence = nil
        state = .idle
        retrySoon()
    }

    private func retrySoon() {
        guard wantConnection else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.tryConnect() }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == role.service {
            peripheral.discoverCharacteristics([role.measurement], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] where c.uuid == role.measurement {
            peripheral.setNotifyValue(true, for: c)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == role.measurement, let data = characteristic.value else { return }
        let now = Date()
        switch role {
        case .power:
            guard let reading = CyclingPowerReading.parse(data) else { return }
            watts = reading.watts
            lastPower = now
            smoothed.add(Double(reading.watts), at: now)
            if let crank = reading.crank { updateCadence(crank, now) }
        case .cadence:
            if let crank = CrankData.parseCSC(data) { updateCadence(crank, now) }
        }
    }

    private func updateCadence(_ crank: CrankData, _ now: Date) {
        if let rpm = cadenceCalc.update(crank, at: now) {
            cadence = rpm
            lastCadence = now
        }
    }
}

/// The ride sensors, shared through the environment as one object.
@MainActor
final class CyclingSensors: ObservableObject {
    let power = CyclingSensor(role: .power)
    let cadence = CyclingSensor(role: .cadence)
}
