// © 2026 High Gain Design. All rights reserved.

import SwiftUI
import HiDockKit

struct DeviceInfoView: View {
    @Bindable var state: AppState
    @State private var showFormatConfirmation = false
    @State private var formatConfirmText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let device = state.device.model {
                    deviceSection(device)
                    batterySection(device)
                    storageSection(device)
                    timeSection(device)
                    settingsSection(device)
                    dangerSection
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 480, height: 560)
        .navigationTitle("Device Info")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .alert("Format SD Card", isPresented: $showFormatConfirmation) {
            TextField("Type ERASE to confirm", text: $formatConfirmText)
            Button("Cancel", role: .cancel) {
                formatConfirmText = ""
            }
            Button("Format", role: .destructive) {
                if formatConfirmText == "ERASE" {
                    Task { await state.formatCard() }
                }
                formatConfirmText = ""
            }
            .disabled(formatConfirmText != "ERASE")
        } message: {
            Text("This will permanently erase all recordings on the device. This cannot be undone.\n\nType ERASE to confirm.")
        }
        .task {
            await state.refreshDeviceTime()
        }
    }

    // MARK: - Device

    private func deviceSection(_ device: DeviceModel) -> some View {
        Section("Device") {
            LabeledContent("Model", value: device.model.rawValue)
            LabeledContent("Serial Number", value: device.serialNumber.isEmpty ? "—" : device.serialNumber)
            LabeledContent("Firmware", value: device.firmwareVersion.isEmpty ? "—" : device.firmwareVersion)
        }
    }

    // MARK: - Battery

    private func batterySection(_ device: DeviceModel) -> some View {
        Section("Battery") {
            if let battery = device.battery {
                LabeledContent("Level") {
                    HStack(spacing: 6) {
                        batteryIcon(battery)
                        Text("\(battery.level)%")
                            .monospacedDigit()
                    }
                }
                LabeledContent("Status", value: batteryStatusText(battery))
                if let mv = battery.voltageMV {
                    LabeledContent("Voltage") {
                        Text(String(format: "%.2f V", Double(mv) / 1000.0))
                            .monospacedDigit()
                    }
                }
            } else {
                Text("Not available")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Storage

    private func storageSection(_ device: DeviceModel) -> some View {
        Section("Storage") {
            if let card = device.cardInfo, card.isInserted {
                LabeledContent("Capacity") {
                    Text(formatBytes(card.totalBytes))
                        .monospacedDigit()
                }
                LabeledContent("Used") {
                    Text("\(formatBytes(card.usedBytes)) (\(String(format: "%.0f%%", card.usagePercent)))")
                        .monospacedDigit()
                }
                LabeledContent("Free") {
                    Text(formatBytes(card.freeBytes))
                        .monospacedDigit()
                }
                LabeledContent("Files on Device", value: "\(device.files.count)")
                LabeledContent("Est. Recording Time") {
                    Text(estimatedRecordingTime(freeBytes: card.freeBytes))
                        .monospacedDigit()
                }

                ProgressView(value: card.usagePercent, total: 100)
                    .tint(DeviceColors.storageColor(card.usagePercent))
            } else {
                Text("No card inserted")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Time

    private func timeSection(_ device: DeviceModel) -> some View {
        Section("Clock") {
            if let deviceTime = device.deviceTime {
                LabeledContent("Device Time") {
                    Text(deviceTime, style: .date)
                    Text(deviceTime, style: .time)
                }
                let drift = deviceTime.timeIntervalSince(Date())
                LabeledContent("Drift") {
                    let absDrift = abs(drift)
                    if absDrift < 2 {
                        Text("In sync")
                            .foregroundStyle(.green)
                    } else {
                        Text(String(format: "%+.0fs", drift))
                            .monospacedDigit()
                            .foregroundStyle(absDrift > 60 ? .red : .orange)
                    }
                }
                Button("Sync Clock Now") {
                    Task { await state.syncClock() }
                }
            } else {
                Text("Not available")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Settings

    @ViewBuilder
    private func settingsSection(_ device: DeviceModel) -> some View {
        if let settings = device.settings {
            DeviceSettingsSection(settings: settings) { updated in
                Task { await state.updateDeviceSettings(updated) }
            }
        } else {
            Section("Device Settings") {
                Text("Not available")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Danger Zone

    private var dangerSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Format SD Card")
                        .font(.body.weight(.medium))
                    Text("Erase all recordings on the device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Format...", role: .destructive) {
                    formatConfirmText = ""
                    showFormatConfirmation = true
                }
                .disabled(state.device.isFormattingCard)
            }
        } header: {
            Label("Danger Zone", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func batteryIcon(_ battery: BatteryInfo) -> some View {
        let icon: String = switch battery.status {
        case .charging: "bolt.fill"
        case .full: "battery.100.bolt"
        case .idle:
            if battery.level > 75 { "battery.100" }
            else if battery.level > 50 { "battery.75" }
            else if battery.level > 25 { "battery.50" }
            else { "battery.25" }
        }
        Image(systemName: icon)
            .foregroundStyle(DeviceColors.batteryColor(battery.level))
    }

    private func batteryStatusText(_ battery: BatteryInfo) -> String {
        switch battery.status {
        case .idle: "On Battery"
        case .charging: "Charging"
        case .full: "Fully Charged"
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Estimate remaining recording time based on free space.
    /// HiDock records WAV at ~48kHz 16-bit mono ≈ 96 KB/s, or ~5.6 MB/min.
    private func estimatedRecordingTime(freeBytes: UInt64) -> String {
        let bytesPerMinute: Double = 5_600_000  // ~5.6 MB/min for WAV mono 48kHz/16-bit
        let minutes = Double(freeBytes) / bytesPerMinute
        if minutes < 60 {
            return String(format: "~%.0f min", minutes)
        }
        let hours = minutes / 60
        if hours < 24 {
            return String(format: "~%.1f hours", hours)
        }
        let days = hours / 24
        return String(format: "~%.0f days", days)
    }
}
