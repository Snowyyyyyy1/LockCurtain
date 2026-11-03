// 开发用的蓝牙探针：只进 DEBUG 包（design v2.9 P1-1），正式包里没有这段代码
#if DEBUG
import Foundation
import CoreBluetooth
import Combine

/// The one service UUID the probe scans for, and the Mac advertiser exposes.
/// Keep these constant: the Mac CLI in /tmp/lc-ble/macadvertise uses the same
/// values. Short forms are only labels for humans, not UUID aliases.
enum ProbeIdentity {
    static let serviceUUIDString = "E9A1B2C3-D4E5-4F60-8A7B-1C2D3E4F5A6B"
    static let commandCharacteristicUUIDString = "E9A1B2C3-D4E5-4F60-8A7B-1C2D3E4F5A6C"

    // Computed so the non-Sendable CBUUID is never shared global state.
    static var serviceUUID: CBUUID { CBUUID(string: serviceUUIDString) }
    static var commandCharacteristicUUID: CBUUID { CBUUID(string: commandCharacteristicUUIDString) }

    /// Short name derived from the service UUID, for log lines and docs.
    static let shortName = "LCB-E9A1"
    /// First 8 hex digits of the service UUID, for log lines and docs.
    static let shortUUID = "E9A1B2C3"
    /// The command the probe writes.
    static let command = "AWAY"
}

struct Discovery: Identifiable {
    let peripheral: CBPeripheral
    let id: UUID
    var name: String
    var rssi: Int
    var advertisedServiceUUIDs: [String]
    var hasProbeService: Bool
    var connectable: Bool
    var lastSeen: Date
}

enum ScanMode: String, CaseIterable, Identifiable {
    case filtered = "Service-filtered"
    case unfiltered = "Unfiltered (all)"

    var id: String { rawValue }
}

/// A deliberately small CoreBluetooth central used only as a feasibility probe.
/// Delegate callbacks arrive on the main queue, so published state is always
/// mutated on the main thread without any actor annotation.
final class BLEProbe: NSObject, ObservableObject {
    @Published private(set) var bluetoothState: String = "unknown"
    @Published private(set) var isScanning = false
    @Published private(set) var discoveries: [Discovery] = []
    @Published private(set) var logLines: [String] = []
    @Published private(set) var connectionState: String = "not connected"
    @Published private(set) var reply: String = "—"
    @Published private(set) var lastWriteResult: String = "—"
    @Published var scanMode: ScanMode = .filtered {
        didSet {
            guard oldValue != scanMode, isScanning else { return }
            startScan()
        }
    }
    @Published private(set) var filteredScanFoundCount = 0
    @Published private(set) var unfilteredScanFoundCount = 0

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var discoveryOrder: [UUID] = []
    private var filteredScanIDs: Set<UUID> = []
    private var unfilteredScanIDs: Set<UUID> = []
    private var connectedPeripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var hasStarted = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
    }

    // MARK: - Public actions

    func startScan() {
        guard central.state == .poweredOn else {
            log("scan requested but Bluetooth state is \(bluetoothState)")
            return
        }
        central.stopScan()
        let services = scanMode == .filtered ? [ProbeIdentity.serviceUUID] : nil
        isScanning = true
        log("scan start mode=\(scanMode.rawValue) services=\(services?.map(\.uuidString).joined(separator: ",") ?? "nil (all)")")
        central.scanForPeripherals(
            withServices: services,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func stopScan() {
        guard isScanning else { return }
        central.stopScan()
        isScanning = false
        log("scan stopped")
    }

    func toggleScan() {
        if isScanning { stopScan() } else { startScan() }
    }

    func connect(_ peripheral: CBPeripheral) {
        guard central.state == .poweredOn else {
            log("cannot connect: Bluetooth state is \(bluetoothState)")
            return
        }
        stopScan()
        if let old = connectedPeripheral, old !== peripheral {
            central.cancelPeripheralConnection(old)
        }
        connectedPeripheral = peripheral
        commandCharacteristic = nil
        connectionState = "connecting to \(peripheral.name ?? peripheral.identifier.uuidString)…"
        reply = "—"
        lastWriteResult = "—"
        log("connect → \(peripheral.name ?? "unnamed") [\(shortID(peripheral.identifier))]")
        central.connect(peripheral, options: nil)
    }

    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        central.cancelPeripheralConnection(peripheral)
    }

    func writeCommand() {
        guard let peripheral = connectedPeripheral, let characteristic = commandCharacteristic else {
            log("write skipped: no connected peripheral/characteristic")
            return
        }
        let data = Data(ProbeIdentity.command.utf8)
        log("write \(ProbeIdentity.command) (\(data.count) bytes) type=withResponse")
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }

    func clearLog() {
        logLines.removeAll()
        log("log cleared")
    }

    /// One plain-text summary of everything the probe has observed, so the person
    /// holding the phone can paste the result instead of describing the screen.
    func reportText() -> String {
        var lines: [String] = []
        lines.append("LCB probe report")
        lines.append("bluetooth=\(bluetoothState) scanning=\(isScanning) mode=\(scanMode.rawValue)")
        lines.append("found filtered=\(filteredScanFoundCount) unfiltered=\(unfilteredScanFoundCount)")
        if discoveries.isEmpty {
            lines.append("discoveries: none")
        } else {
            lines.append("discoveries: \(discoveries.count)")
            for discovery in discoveries {
                let services = discovery.advertisedServiceUUIDs.isEmpty ? "-" : discovery.advertisedServiceUUIDs.joined(separator: "+")
                lines.append("  \(discovery.name) rssi=\(discovery.rssi) connectable=\(discovery.connectable ? "yes" : "no") probeService=\(discovery.hasProbeService ? "YES" : "NO") advServices=\(services)")
            }
        }
        lines.append("connection=\(connectionState)")
        lines.append("lastWrite=\(lastWriteResult)")
        lines.append("reply=\(reply)")
        lines.append("log tail:")
        lines.append(contentsOf: logLines.suffix(12).map { "  " + $0 })
        return lines.joined(separator: "\n")
    }

    // MARK: - Logging

    func log(_ text: String) {
        let line = "\(Self.timeFormatter.string(from: Date()))  \(text)"
        logLines.append(line)
        if logLines.count > 40 {
            logLines.removeFirst(logLines.count - 40)
        }
    }

    private func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    private func peripheryCleanup() {
        connectedPeripheral?.delegate = nil
        commandCharacteristic = nil
    }

    // MARK: - Advertisement parsing

    private func update(_ peripheral: CBPeripheral, advertisementData: [String: Any], rssi: Int) {
        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let overflow = (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? []
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? "(unnamed)"
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? Bool) ?? false
        let hasService = advertised.contains(ProbeIdentity.serviceUUID)
        let advertisedStrings = advertised.map(\.uuidString)
        let isNew = peripherals[peripheral.identifier] == nil

        peripherals[peripheral.identifier] = peripheral
        if isNew { discoveryOrder.append(peripheral.identifier) }

        let discovery = Discovery(
            peripheral: peripheral,
            id: peripheral.identifier,
            name: name,
            rssi: rssi,
            advertisedServiceUUIDs: advertisedStrings,
            hasProbeService: hasService,
            connectable: connectable,
            lastSeen: Date()
        )
        if let index = discoveries.firstIndex(where: { $0.id == peripheral.identifier }) {
            discoveries[index] = discovery
        } else {
            discoveries.append(discovery)
        }
        discoveries.sort { $0.rssi > $1.rssi }

        if scanMode == .filtered { filteredScanIDs.insert(peripheral.identifier) }
        else { unfilteredScanIDs.insert(peripheral.identifier) }
        filteredScanFoundCount = filteredScanIDs.count
        unfilteredScanFoundCount = unfilteredScanIDs.count

        if isNew {
            log("discovered \(name) [\(shortID(peripheral.identifier))] rssi=\(rssi) services=\(advertisedStrings.isEmpty ? "none" : advertisedStrings.joined(separator: ",")) servicePresent=\(hasService ? "YES" : "NO") connectable=\(connectable ? "YES" : "NO")\(overflow.isEmpty ? "" : " overflow=\(overflow.map(\.uuidString).joined(separator: ","))")")
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEProbe: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothState = "poweredOn"
        case .poweredOff:
            bluetoothState = "poweredOff"
        case .unauthorized:
            bluetoothState = "unauthorized"
        case .unsupported:
            bluetoothState = "unsupported"
        case .resetting:
            bluetoothState = "resetting"
        case .unknown:
            bluetoothState = "unknown"
        @unknown default:
            bluetoothState = "unrecognized(\(central.state.rawValue))"
        }
        log("central state = \(bluetoothState)")
        if central.state == .poweredOn { startScan() }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        update(peripheral, advertisementData: advertisementData, rssi: RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        peripheral.delegate = self
        connectionState = "connected to \(peripheral.name ?? "unnamed")"
        log("connected [\(shortID(peripheral.identifier))]")
        log("discoverServices([\(ProbeIdentity.serviceUUID.uuidString)])")
        peripheral.discoverServices([ProbeIdentity.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        connectionState = "connect failed"
        log("connect failed [\(shortID(peripheral.identifier))] error=\(error?.localizedDescription ?? "nil")")
        peripheryCleanup()
        central.stopScan()
        isScanning = false
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        connectionState = "disconnected"
        log("disconnected [\(shortID(peripheral.identifier))] error=\(error?.localizedDescription ?? "nil")")
        peripheryCleanup()
    }
}

// MARK: - CBPeripheralDelegate

extension BLEProbe: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("discoverServices failed: \(error.localizedDescription)")
            return
        }
        let services = peripheral.services ?? []
        log("services found: \(services.isEmpty ? "none" : services.map(\.uuid.uuidString).joined(separator: ","))")
        guard let service = services.first(where: { $0.uuid == ProbeIdentity.serviceUUID }) else {
            log("probe service not present after connect")
            return
        }
        log("discoverCharacteristics(nil) for \(service.uuid.uuidString)")
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            log("discoverCharacteristics failed: \(error.localizedDescription)")
            return
        }
        let characteristics = service.characteristics ?? []
        for characteristic in characteristics {
            log("characteristic \(characteristic.uuid.uuidString) props=\(properties(characteristic.properties))")
        }
        guard let characteristic = characteristics.first(where: {
            $0.uuid == ProbeIdentity.commandCharacteristicUUID
        }) else {
            log("command characteristic not found")
            return
        }
        commandCharacteristic = characteristic
        log("subscribing to notifications")
        peripheral.setNotifyValue(true, for: characteristic)
        log("reading initial value")
        peripheral.readValue(for: characteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        log("notify state=\(characteristic.isNotifying ? "ON" : "OFF") for \(characteristic.uuid.uuidString) error=\(error?.localizedDescription ?? "nil")")
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            lastWriteResult = "FAILED: \(error.localizedDescription)"
            log("write failed: \(error.localizedDescription)")
        } else {
            lastWriteResult = "ok (\(ProbeIdentity.command))"
            log("write ok; reading reply")
            peripheral.readValue(for: characteristic)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            log("read/notify failed: \(error.localizedDescription)")
            return
        }
        let data = characteristic.value ?? Data()
        let text = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes, not UTF-8>"
        reply = text
        log("reply (\(data.count) bytes): \(text)")
    }

    private func properties(_ props: CBCharacteristicProperties) -> String {
        var names: [String] = []
        if props.contains(.read) { names.append("read") }
        if props.contains(.write) { names.append("write") }
        if props.contains(.writeWithoutResponse) { names.append("writeNoResp") }
        if props.contains(.notify) { names.append("notify") }
        if props.contains(.indicate) { names.append("indicate") }
        return names.isEmpty ? "none" : names.joined(separator: "+")
    }
}
#endif
