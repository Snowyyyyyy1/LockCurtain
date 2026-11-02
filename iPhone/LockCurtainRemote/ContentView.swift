import SwiftUI
import UIKit

/// One plain debug screen. It is the feasibility probe, not the app's UI:
/// everything here exists to answer whether macOS can advertise the service
/// and whether iOS can find it, read its RSSI and write a command.
struct ContentView: View {
    @StateObject private var probe = BLEProbe()

    private static let seenFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        NavigationStack {
            List {
                identitySection
                discoverySection
                connectionSection
                logSection
                notesSection
            }
            .navigationTitle("BLE probe")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Identity

    private var identitySection: some View {
        Section("Probe target") {
            LabeledContent("Short name", value: ProbeIdentity.shortName)
            LabeledContent("Short UUID", value: ProbeIdentity.shortUUID)
            VStack(alignment: .leading, spacing: 2) {
                Text("Service UUID").font(.caption).foregroundStyle(.secondary)
                Text(ProbeIdentity.serviceUUID.uuidString)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Command characteristic").font(.caption).foregroundStyle(.secondary)
                Text(ProbeIdentity.commandCharacteristicUUID.uuidString)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            LabeledContent("Command written", value: ProbeIdentity.command)

            Picker("Scan mode", selection: $probe.scanMode) {
                ForEach(ScanMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            LabeledContent("Bluetooth", value: probe.bluetoothState)
            LabeledContent("Scanning", value: probe.isScanning ? "yes" : "no")
            LabeledContent("Found (service-filtered)", value: "\(probe.filteredScanFoundCount)")
            LabeledContent("Found (unfiltered)", value: "\(probe.unfilteredScanFoundCount)")

            Button(probe.isScanning ? "Stop scan" : "Start scan") {
                probe.toggleScan()
            }
            .accessibilityIdentifier("scan-toggle")

            Button("Copy report") {
                UIPasteboard.general.string = probe.reportText()
                probe.log("report copied to clipboard")
            }
            .accessibilityIdentifier("copy-report")
        }
    }

    // MARK: - Discoveries

    private var discoverySection: some View {
        Section("Discovered (\(probe.discoveries.count))") {
            if probe.discoveries.isEmpty {
                Text(probe.isScanning
                     ? "Scanning… no peripherals yet."
                     : "No peripherals. Start a scan.")
                    .foregroundStyle(.secondary)
            }
            ForEach(probe.discoveries) { discovery in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(discovery.name)
                            .font(.headline)
                        Spacer()
                        Text("\(discovery.rssi) dBm")
                            .font(.body.monospacedDigit())
                    }
                    Text("id \(String(discovery.id.uuidString.prefix(8))) · connectable \(discovery.connectable ? "yes" : "no") · seen \(Self.seenFormatter.string(from: discovery.lastSeen))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("adv service UUIDs: \(discovery.advertisedServiceUUIDs.isEmpty ? "none" : discovery.advertisedServiceUUIDs.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("probe service in kCBAdvDataServiceUUIDs: \(discovery.hasProbeService ? "YES" : "NO")")
                        .font(.caption)
                        .foregroundStyle(discovery.hasProbeService ? .green : .orange)
                    HStack {
                        Spacer()
                        Button("Connect") {
                            probe.connect(discovery.peripheral)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("connect-\(String(discovery.id.uuidString.prefix(8)))")
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section("Connection") {
            LabeledContent("State", value: probe.connectionState)
            VStack(alignment: .leading, spacing: 2) {
                Text("Last write").font(.caption).foregroundStyle(.secondary)
                Text(probe.lastWriteResult).font(.body.monospaced())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Reply").font(.caption).foregroundStyle(.secondary)
                Text(probe.reply)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            HStack {
                Button("Write \(ProbeIdentity.command)") {
                    probe.writeCommand()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("write-command")
                Spacer()
                Button("Disconnect") {
                    probe.disconnect()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Log

    private var logSection: some View {
        Section("Log (last 40)") {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(probe.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(minHeight: 180, maxHeight: 380)

            Button("Clear log") {
                probe.clearLog()
            }
            .controlSize(.small)
        }
    }

    // MARK: - Notes

    private var notesSection: some View {
        Section("Notes") {
            Text("iOS merges the advertising packet and the scan response into kCBAdvDataServiceUUIDs, so YES here does not prove the UUID is in the advertising packet itself. The real check is the pair of scans: service-filtered finds nothing while unfiltered finds the Mac.")
                .font(.footnote)
            Text("RSSI is the value CoreBluetooth reports per discovery; it is not a distance measurement.")
                .font(.footnote)
            Text("Connect → discover services/characteristics → write \(ProbeIdentity.command) → read reply. The Mac advertiser must expose the service above.")
                .font(.footnote)
        }
    }
}

#Preview {
    ContentView()
}
