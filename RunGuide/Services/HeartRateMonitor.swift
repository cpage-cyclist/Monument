import CoreBluetooth
import Foundation

/// Connects to any Bluetooth heart-rate strap using the standard Heart Rate
/// profile (service 0x180D), which every mainstream chest strap supports.
/// Remembers the paired strap and reconnects to it automatically.
final class HeartRateMonitor: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    struct Found: Identifiable, Hashable {
        let id: UUID
        let name: String
    }

    enum State: Equatable {
        case off, idle, scanning, connecting, connected
    }

    @Published private(set) var bpm: Int?
    @Published private(set) var state: State = .idle
    @Published private(set) var found: [Found] = []
    @Published private(set) var pairedName: String?

    private static let hrService = CBUUID(string: "180D")
    private static let hrMeasurement = CBUUID(string: "2A37")
    private let pairedKey = "pairedHeartRateStrap"
    private let pairedNameKey = "pairedHeartRateStrapName"

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var seen: [UUID: CBPeripheral] = [:]
    private var wantConnection = false
    private var wantScan = false
    private var lastReading: Date?

    override init() {
        super.init()
        pairedName = UserDefaults.standard.string(forKey: pairedNameKey)
    }

    var hasPairedStrap: Bool { pairedID != nil }

    private var pairedID: UUID? {
        UserDefaults.standard.string(forKey: pairedKey).flatMap(UUID.init(uuidString:))
    }

    /// A reading older than 5 s is treated as no reading.
    var currentBPM: Int? {
        guard let bpm, let lastReading, Date().timeIntervalSince(lastReading) < 5 else { return nil }
        return bpm
    }

    // MARK: - Public actions

    func startScan() {
        found = []
        wantScan = true
        ensureCentral()
        guard central?.state == .poweredOn else { return }
        state = .scanning
        central?.scanForPeripherals(withServices: [Self.hrService])
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

    /// Connect to the paired strap (no-op if none is paired).
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
        bpm = nil
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
            // Not cached yet: scan until it shows up.
            state = .connecting
            central.scanForPeripherals(withServices: [Self.hrService])
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            if state == .off { state = .idle }
            if wantScan {
                state = .scanning
                central.scanForPeripherals(withServices: [Self.hrService])
            }
            tryConnect()
        } else {
            state = .off
            bpm = nil
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        seen[peripheral.identifier] = peripheral
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "Heart-rate strap"
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
        peripheral.discoverServices([Self.hrService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .idle
        retrySoon()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        bpm = nil
        state = .idle
        retrySoon()
    }

    private func retrySoon() {
        guard wantConnection else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.tryConnect() }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == Self.hrService {
            peripheral.discoverCharacteristics([Self.hrMeasurement], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] where c.uuid == Self.hrMeasurement {
            peripheral.setNotifyValue(true, for: c)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.hrMeasurement,
              let data = characteristic.value,
              let value = Self.parseHeartRate(data) else { return }
        bpm = value
        lastReading = Date()
    }

    /// Heart Rate Measurement: flags byte, then 8- or 16-bit bpm (bit 0 of flags).
    static func parseHeartRate(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        if bytes[0] & 0x01 == 0 {
            return Int(bytes[1])
        }
        guard bytes.count >= 3 else { return nil }
        return Int(bytes[1]) | Int(bytes[2]) << 8
    }
}
