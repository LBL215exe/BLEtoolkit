import Foundation
import CoreBluetooth
import Combine
import UniformTypeIdentifiers

// MARK: - Models
struct DiscoveredDevice: Identifiable {
    let id: String
    let uuid: String
    let name: String
    let rssi: Int
    let advertisedServices: [String]
    let manufacturerData: String?
    let peripheral: CBPeripheral
}

struct BLEService: Identifiable {
    let id: String
    let uuid: String
    let name: String
    var characteristics: [BLECharacteristic]
}

struct BLECharacteristic: Identifiable {
    let id: String
    let uuid: String
    let name: String
    var properties: [String]
    var valueHex: String?
    var valueAscii: String?
    var valueBytes: [UInt8]?
    var isNotifying: Bool
    var writeInput: String
    let cbChar: CBCharacteristic?
}

struct CapturedNotification: Identifiable {
    let id = UUID()
    let timestamp: String
    let charUUID: String
    let hex: String
    let bytes: [UInt8]
}

struct ReplayData {
    let deviceName: String
    var services: [[String: Any]]
    var writableChars: [(uuid: String, hex: String, bytes: [UInt8])]
    var notifications: [(uuid: String, hex: String, bytes: [UInt8])]
    var writableCount: Int { writableChars.count }
}

// MARK: - BLE Manager
class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var connectedDevice: DiscoveredDevice?
    @Published var services: [BLEService] = []
    @Published var notifications: [CapturedNotification] = []
    @Published var logEntries: [String] = ["[SYSTEM] BLE Toolkit initialized"]
    @Published var isScanning = false
    @Published var replayData: ReplayData?
    @Published var replayLog: [String] = []
    @Published var isReadyForReplay = false

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var replayPeripheral: CBPeripheral?
    private var discoveredPeripherals: [String: CBPeripheral] = [:]
    private var charMap: [String: CBCharacteristic] = [:]

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func log(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date()).suffix(13).prefix(12)
        let entry = "[\(ts)] \(msg)"
        DispatchQueue.main.async { self.logEntries.append(entry) }
    }

    // MARK: - Scanning
    func startScanning() {
        guard centralManager.state == .poweredOn else {
            log("[ERR] Bluetooth not powered on")
            return
        }
        discoveredDevices = []
        discoveredPeripherals = [:]
        isScanning = true
        log("[SCAN] Starting BLE scan...")
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.stopScanning()
        }
    }

    func stopScanning() {
        centralManager.stopScan()
        isScanning = false
        log("[SCAN] Stopped. Found \(discoveredDevices.count) devices.")
    }

    // MARK: - Connection
    func connect(to device: DiscoveredDevice) {
        log("[CONNECT] Connecting to \(device.name)...")
        services = []
        notifications = []
        charMap = [:]
        centralManager.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        if let p = connectedPeripheral {
            centralManager.cancelPeripheralConnection(p)
            connectedDevice = nil
            connectedPeripheral = nil
            log("[DISCONNECT] Disconnected")
        }
    }

    // MARK: - Write
    func updateWriteInput(charID: String, value: String) {
        for si in services.indices {
            for ci in services[si].characteristics.indices {
                if services[si].characteristics[ci].id == charID {
                    services[si].characteristics[ci].writeInput = value
                }
            }
        }
    }

    func writeValue(charID: String) {
        guard let char = charMap[charID] else { log("[WRITE ERR] Char not found"); return }
        var input = ""
        for svc in services {
            for c in svc.characteristics where c.id == charID {
                input = c.writeInput
            }
        }
        let hexBytes = input.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        guard !hexBytes.isEmpty else { log("[WRITE ERR] Invalid hex"); return }
        let data = Data(hexBytes)
        let type: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        connectedPeripheral?.writeValue(data, for: char, type: type)
        log("[WRITE] \(char.uuid.uuidString) ← \(hexBytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
    }

    // MARK: - Export
    func exportCapture() {
        var data: [String: Any] = [
            "device": connectedDevice?.name ?? "Unknown",
            "deviceID": connectedDevice?.uuid ?? "",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        var svcs: [[String: Any]] = []
        for svc in services {
            var chars: [[String: Any]] = []
            for c in svc.characteristics {
                var cd: [String: Any] = [
                    "uuid": c.uuid,
                    "properties": c.properties
                ]
                if let v = c.valueBytes { cd["value"] = v }
                if let h = c.valueHex { cd["valueHex"] = h }
                chars.append(cd)
            }
            svcs.append(["uuid": svc.uuid, "characteristics": chars])
        }
        data["services"] = svcs
        data["notifications"] = notifications.map { ["ts": $0.timestamp, "uuid": $0.charUUID, "hex": $0.hex, "bytes": $0.bytes] }

        if let json = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ble_capture_\(Int(Date().timeIntervalSince1970)).json")
            try? json.write(to: url)
            log("[EXPORT] Saved to \(url.lastPathComponent)")
            // Share sheet
            let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let vc = scene.windows.first?.rootViewController {
                vc.present(av, animated: true)
            }
        }
    }

    // MARK: - Replay
    func loadCurrentAsReplay() {
        var writable: [(uuid: String, hex: String, bytes: [UInt8])] = []
        for svc in services {
            for c in svc.characteristics {
                if let bytes = c.valueBytes, (c.properties.contains("WRITE") || c.properties.contains("WRITE_NR")) {
                    writable.append((uuid: c.uuid, hex: c.valueHex ?? "", bytes: bytes))
                }
            }
        }
        let notifs = notifications.map { (uuid: $0.charUUID, hex: $0.hex, bytes: $0.bytes) }
        replayData = ReplayData(deviceName: connectedDevice?.name ?? "Unknown", services: [], writableChars: writable, notifications: notifs)
        log("[REPLAY] Loaded current session: \(writable.count) writable, \(notifs.count) notifications")
    }

    func loadReplayFile(url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("[REPLAY] Failed to parse JSON"); return
        }
        var writable: [(uuid: String, hex: String, bytes: [UInt8])] = []
        if let svcs = json["services"] as? [[String: Any]] {
            for svc in svcs {
                if let chars = svc["characteristics"] as? [[String: Any]] {
                    for c in chars {
                        let props = c["properties"] as? [String] ?? []
                        if let bytes = c["value"] as? [Int], (props.contains("WRITE") || props.contains("WRITE_NR")) {
                            let ub = bytes.map { UInt8($0) }
                            writable.append((uuid: c["uuid"] as? String ?? "", hex: c["valueHex"] as? String ?? "", bytes: ub))
                        }
                    }
                }
            }
        }
        var notifs: [(uuid: String, hex: String, bytes: [UInt8])] = []
        if let ns = json["notifications"] as? [[String: Any]] {
            for n in ns {
                let bytes = (n["bytes"] as? [Int] ?? []).map { UInt8($0) }
                notifs.append((uuid: n["uuid"] as? String ?? "", hex: n["hex"] as? String ?? "", bytes: bytes))
            }
        }
        replayData = ReplayData(deviceName: json["device"] as? String ?? "Unknown", services: [], writableChars: writable, notifications: notifs)
        log("[REPLAY] Loaded file: \(writable.count) writable, \(notifs.count) notifications")
    }

    func connectForReplay() {
        log("[REPLAY] Scan for target device...")
        startScanning()
        // User picks device from scan tab, then comes back
    }

    func executeReplay() {
        guard let peripheral = connectedPeripheral, let replay = replayData else {
            log("[REPLAY] Not connected or no data"); return
        }
        replayLog = []
        log("[REPLAY] Executing replay on \(peripheral.name ?? "Unknown")...")

        // We need to discover services first, then write
        // For now, write to known characteristics
        for item in replay.writableChars {
            if let char = charMap.values.first(where: { $0.uuid.uuidString.lowercased() == item.uuid.lowercased() }) {
                let data = Data(item.bytes)
                let type: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
                peripheral.writeValue(data, for: char, type: type)
                let msg = "[OK] \(item.uuid) ← \(item.hex)"
                replayLog.append(msg)
                log(msg)
            } else {
                let msg = "[SKIP] \(item.uuid) — not found on target"
                replayLog.append(msg)
                log(msg)
            }
        }

        for notif in replay.notifications {
            if let char = charMap.values.first(where: { $0.uuid.uuidString.lowercased() == notif.uuid.lowercased() }),
               char.properties.contains(.write) || char.properties.contains(.writeWithoutResponse) {
                let data = Data(notif.bytes)
                let type: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
                peripheral.writeValue(data, for: char, type: type)
                let msg = "[NOTIF→WRITE] \(notif.uuid) ← \(notif.hex)"
                replayLog.append(msg)
                log(msg)
            }
        }
        replayLog.append("✅ Replay complete")
        log("[REPLAY] Complete")
    }

    // MARK: - CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: log("[BT] Bluetooth powered on")
        case .poweredOff: log("[BT] Bluetooth powered off")
        case .unauthorized: log("[BT] Unauthorized")
        case .unsupported: log("[BT] BLE not supported")
        default: log("[BT] State: \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let uuid = peripheral.identifier.uuidString
        guard discoveredPeripherals[uuid] == nil else { return }
        discoveredPeripherals[uuid] = peripheral

        var advServices: [String] = []
        if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            advServices = uuids.map { $0.uuidString }
        }
        var mfrData: String?
        if let mfr = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            mfrData = mfr.map { String(format: "%02x", $0) }.joined(separator: " ")
        }

        let device = DiscoveredDevice(
            id: uuid, uuid: uuid,
            name: peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown",
            rssi: RSSI.intValue,
            advertisedServices: advServices,
            manufacturerData: mfrData,
            peripheral: peripheral
        )
        discoveredDevices.append(device)
        log("[FOUND] \(device.name) RSSI:\(device.rssi) [\(uuid.prefix(8))]")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        peripheral.delegate = self
        connectedDevice = discoveredDevices.first { $0.uuid == peripheral.identifier.uuidString }
        isReadyForReplay = true
        log("[CONNECTED] \(peripheral.name ?? "Unknown")")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("[CONNECT FAIL] \(error?.localizedDescription ?? "Unknown error")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("[DISCONNECTED] \(peripheral.name ?? "Unknown")")
        connectedDevice = nil
        connectedPeripheral = nil
        isReadyForReplay = false
    }

    // MARK: - CBPeripheralDelegate
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svcs = peripheral.services else { return }
        log("[SERVICES] Found \(svcs.count) services")
        for svc in svcs {
            let bleService = BLEService(id: svc.uuid.uuidString, uuid: svc.uuid.uuidString, name: svc.uuid.description, characteristics: [])
            services.append(bleService)
            peripheral.discoverCharacteristics(nil, for: svc)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        guard let svcIdx = services.firstIndex(where: { $0.uuid == service.uuid.uuidString }) else { return }

        for char in chars {
            var props: [String] = []
            if char.properties.contains(.read) { props.append("READ") }
            if char.properties.contains(.write) { props.append("WRITE") }
            if char.properties.contains(.writeWithoutResponse) { props.append("WRITE_NR") }
            if char.properties.contains(.notify) { props.append("NOTIFY") }
            if char.properties.contains(.indicate) { props.append("INDICATE") }

            let bleChar = BLECharacteristic(
                id: char.uuid.uuidString,
                uuid: char.uuid.uuidString,
                name: char.uuid.description,
                properties: props,
                isNotifying: false,
                writeInput: "",
                cbChar: char
            )
            services[svcIdx].characteristics.append(bleChar)
            charMap[char.uuid.uuidString] = char

            if char.properties.contains(.read) {
                peripheral.readValue(for: char)
            }
            if char.properties.contains(.notify) || char.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: char)
            }
            log("[CHAR] \(char.uuid.uuidString) [\(props.joined(separator: ","))]")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid.uuidString
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        let ascii = String(bytes.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." })

        // Update characteristic value
        for si in services.indices {
            for ci in services[si].characteristics.indices {
                if services[si].characteristics[ci].uuid == uuid {
                    services[si].characteristics[ci].valueHex = hex
                    services[si].characteristics[ci].valueAscii = ascii
                    services[si].characteristics[ci].valueBytes = bytes
                }
            }
        }

        // If notifying, add to notifications
        if characteristic.isNotifying {
            let ts = ISO8601DateFormatter().string(from: Date()).suffix(13).prefix(12)
            let notif = CapturedNotification(timestamp: String(ts), charUUID: uuid, hex: hex, bytes: bytes)
            notifications.append(notif)
            log("[NOTIFY] \(uuid) → \(hex)")
        } else {
            log("[READ] \(uuid) = \(hex)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid.uuidString
        for si in services.indices {
            for ci in services[si].characteristics.indices {
                if services[si].characteristics[ci].uuid == uuid {
                    services[si].characteristics[ci].isNotifying = characteristic.isNotifying
                }
            }
        }
        if characteristic.isNotifying {
            log("[SUBSCRIBE] \(uuid) — notifications active")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let err = error {
            log("[WRITE ERR] \(characteristic.uuid.uuidString): \(err.localizedDescription)")
        } else {
            log("[WRITE OK] \(characteristic.uuid.uuidString)")
        }
    }
}
