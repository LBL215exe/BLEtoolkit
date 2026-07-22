import SwiftUI

struct ContentView: View {
    @StateObject private var ble = BLEManager()
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ScanView(ble: ble)
                .tabItem { Label("Scan", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(0)

            CaptureView(ble: ble)
                .tabItem { Label("Capture", systemImage: "waveform") }
                .tag(1)

            ReplayView(ble: ble)
                .tabItem { Label("Replay", systemImage: "arrow.triangle.2.circlepath") }
                .tag(2)

            LogView(ble: ble)
                .tabItem { Label("Log", systemImage: "doc.text") }
                .tag(3)
        }
        .accentColor(.blue)
    }
}

// MARK: - Scan Tab
struct ScanView: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Button(action: { ble.startScanning() }) {
                            Label(ble.isScanning ? "Scanning..." : "Start Scan", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        .disabled(ble.isScanning)

                        Spacer()

                        if ble.isScanning {
                            Button("Stop") { ble.stopScanning() }
                                .foregroundColor(.red)
                        }
                    }
                }

                Section(header: Text("Discovered Devices (\(ble.discoveredDevices.count))")) {
                    if ble.discoveredDevices.isEmpty {
                        Text("No devices found yet")
                            .foregroundColor(.secondary)
                            .italic()
                    }
                    ForEach(ble.discoveredDevices) { device in
                        Button(action: { ble.connect(to: device) }) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(device.name)
                                        .font(.headline)
                                    Spacer()
                                    Text("\(device.rssi) dBm")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Text(device.uuid)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                if !device.advertisedServices.isEmpty {
                                    Text("Services: \(device.advertisedServices.joined(separator: ", "))")
                                        .font(.caption2)
                                        .foregroundColor(.blue)
                                }
                                if let mfr = device.manufacturerData {
                                    Text("Mfr: \(mfr)")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if let connected = ble.connectedDevice {
                    Section(header: Text("Connected")) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(connected.name)
                                .font(.headline)
                            Spacer()
                            Button("Disconnect") { ble.disconnect() }
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("BLE Scanner")
            .refreshable { ble.startScanning() }
        }
    }
}

// MARK: - Capture Tab
struct CaptureView: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        NavigationView {
            List {
                if ble.services.isEmpty {
                    Section {
                        Text("Connect to a device first, then GATT services will be dumped automatically.")
                            .foregroundColor(.secondary)
                            .italic()
                    }
                }

                ForEach(ble.services) { service in
                    Section(header: Text("🔷 \(service.name)").font(.caption)) {
                        Text(service.uuid)
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        ForEach(service.characteristics) { char in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(char.name)
                                        .font(.subheadline)
                                        .bold()
                                    Spacer()
                                }
                                Text(char.uuid)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)

                                // Properties
                                HStack(spacing: 4) {
                                    ForEach(char.properties, id: \.self) { prop in
                                        Text(prop)
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(propColor(prop).opacity(0.2))
                                            .foregroundColor(propColor(prop))
                                            .cornerRadius(4)
                                    }
                                }

                                // Value
                                if let hex = char.valueHex {
                                    HStack {
                                        Text("HEX:")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Text(hex)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundColor(.green)
                                    }
                                }
                                if let ascii = char.valueAscii, !ascii.isEmpty {
                                    HStack {
                                        Text("ASCII:")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Text(ascii)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundColor(.yellow)
                                    }
                                }

                                // Notification status
                                if char.isNotifying {
                                    Text("📡 Listening for notifications...")
                                        .font(.caption2)
                                        .foregroundColor(.purple)
                                }

                                // Write field for writable chars
                                if char.properties.contains("WRITE") || char.properties.contains("WRITE_NR") {
                                    HStack {
                                        TextField("Hex (e.g. 01 ff a3)", text: Binding(
                                            get: { char.writeInput },
                                            set: { ble.updateWriteInput(charID: char.id, value: $0) }
                                        ))
                                        .font(.caption)
                                        .textFieldStyle(.roundedBorder)

                                        Button("Write") {
                                            ble.writeValue(charID: char.id)
                                        }
                                        .font(.caption)
                                        .buttonStyle(.borderedProminent)
                                        .tint(.red)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                // Notifications
                if !ble.notifications.isEmpty {
                    Section(header: Text("📡 Captured Notifications (\(ble.notifications.count))")) {
                        ForEach(ble.notifications) { notif in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(notif.timestamp)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Text("\(notif.charUUID)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.blue)
                                Text(notif.hex)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.green)
                            }
                        }
                    }
                }
            }
            .navigationTitle("GATT Capture")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { ble.exportCapture() }) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    func propColor(_ prop: String) -> Color {
        switch prop {
        case "READ": return .blue
        case "WRITE", "WRITE_NR": return .red
        case "NOTIFY", "INDICATE": return .purple
        default: return .gray
        }
    }
}

// MARK: - Replay Tab
struct ReplayView: View {
    @ObservedObject var ble: BLEManager
    @State private var showFilePicker = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Load Capture")) {
                    Button("📂 Import Capture JSON") { showFilePicker = true }
                    Button("📋 Use Current Session") { ble.loadCurrentAsReplay() }
                }

                if let replay = ble.replayData {
                    Section(header: Text("Replay Data")) {
                        Text("Device: \(replay.deviceName)")
                            .font(.caption)
                        Text("Services: \(replay.services.count)")
                            .font(.caption)
                        Text("Writable chars: \(replay.writableCount)")
                            .font(.caption)
                        Text("Notifications: \(replay.notifications.count)")
                            .font(.caption)

                        ForEach(replay.writableChars, id: \.uuid) { char in
                            VStack(alignment: .leading) {
                                Text(char.uuid)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.blue)
                                Text("→ \(char.hex)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.green)
                            }
                        }
                    }

                    Section(header: Text("Execute")) {
                        Button(action: { ble.connectForReplay() }) {
                            Label("Connect to Target", systemImage: "link")
                        }
                        Button(action: { ble.executeReplay() }) {
                            Label("⚡ Execute Replay", systemImage: "play.fill")
                        }
                        .foregroundColor(.red)
                        .disabled(!ble.isReadyForReplay)
                    }

                    if !ble.replayLog.isEmpty {
                        Section(header: Text("Replay Results")) {
                            ForEach(ble.replayLog, id: \.self) { msg in
                                Text(msg)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(msg.contains("OK") ? .green : msg.contains("FAIL") ? .red : .secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Replay")
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result {
                    ble.loadReplayFile(url: url)
                }
            }
        }
    }
}

// MARK: - Log Tab
struct LogView: View {
    @ObservedObject var ble: BLEManager

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(ble.logEntries.indices, id: \.self) { i in
                            Text(ble.logEntries[i])
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.green)
                                .id(i)
                        }
                    }
                    .padding()
                }
                .background(Color.black)
                .onChange(of: ble.logEntries.count) { _ in
                    withAnimation { proxy.scrollTo(ble.logEntries.count - 1) }
                }
            }
            .navigationTitle("Raw Log")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear") { ble.logEntries = ["[SYSTEM] Log cleared"] }
                }
            }
        }
    }
}
