// © 2026 High Gain Design. All rights reserved.

import SwiftUI
import HiDockKit

struct SidebarView: View {
    @Bindable var state: AppState

    @State private var renamingFolder: String? = nil
    @State private var renameText: String = ""
    @State private var isCreatingFolder: Bool = false
    @State private var newFolderName: String = ""

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $state.selectedView) {
                Section(header: libraryHeader) {
                    Label {
                        HStack {
                            Text("All Recordings")
                            Spacer()
                            if state.library.recordings.count > 0 {
                                Text("\(state.library.recordings.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary)
                                    .clipShape(Capsule())
                            }
                        }
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .tag(SidebarSelection.allRecordings)
                    .dropDestination(for: String.self) { filenames, _ in
                        Task {
                            for filename in filenames {
                                if let rec = state.library.recordings.first(where: { $0.filename == filename }) {
                                    await state.moveRecording(rec, toFolder: nil)
                                }
                            }
                        }
                        return true
                    }

                    ForEach(state.library.folders, id: \.self) { folder in
                        Label {
                            HStack {
                                if renamingFolder == folder {
                                    TextField("Folder name", text: $renameText)
                                        .textFieldStyle(.roundedBorder)
                                        .onSubmit { commitRename(oldName: folder) }
                                        .onExitCommand { renamingFolder = nil }
                                } else {
                                    Text(folder)
                                }
                                Spacer()
                                let count = state.library.recordings.filter { $0.folder == folder }.count
                                if count > 0 {
                                    Text("\(count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.quaternary)
                                        .clipShape(Capsule())
                                }
                            }
                        } icon: {
                            Image(systemName: "folder")
                        }
                        .tag(SidebarSelection.folder(folder))
                        .contextMenu {
                            Button("Rename...") {
                                renameText = folder
                                renamingFolder = folder
                            }
                            Divider()
                            Button("Delete Folder", role: .destructive) {
                                Task { await state.deleteFolder(named: folder) }
                            }
                        }
                        .dropDestination(for: String.self) { filenames, _ in
                            Task {
                                for filename in filenames {
                                    if let rec = state.library.recordings.first(where: { $0.filename == filename }) {
                                        await state.moveRecording(rec, toFolder: folder)
                                    }
                                }
                            }
                            return true
                        }
                    }

                    Button {
                        isCreatingFolder = true
                        newFolderName = ""
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("New Folder")
                }

                if state.device.isConnected, let device = state.device.model {
                    Section("Device") {
                        Label {
                            HStack {
                                Text("HiDock \(device.model.rawValue)")
                                Spacer()
                                Text("\(device.files.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary)
                                    .clipShape(Capsule())
                            }
                        } icon: {
                            Image(systemName: "waveform")
                        }
                        .tag(SidebarSelection.device)
                    }
                }
            }
            .listStyle(.sidebar)

            if let progress = state.syncProgress {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                        .tint(.blue)
                        .controlSize(.small)
                    Text(state.statusMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.blue.opacity(0.05))
            }

            if state.sharedLibrary.phase == .connecting {
                HStack { ProgressView().controlSize(.small); Text("Opening shared library…").font(.caption) }.padding(8)
            } else if state.sharedLibrary.phase == .readOnly {
                Label("Shared library: read-only", systemImage: "lock").font(.caption).foregroundStyle(.secondary).padding(8)
            } else if state.sharedLibrary.phase == .failed {
                Label("Shared library needs attention in Settings", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).padding(8)
            }
            Divider()
            deviceStatusBar
        }
        .frame(minWidth: 200)
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                guard !newFolderName.isEmpty else { return }
                Task {
                    do { try await state.library.createFolder(named: newFolderName) }
                    catch { state.errorMessage = error.localizedDescription }
                }
            }
        } message: {
            Text("Enter a name for the new folder.")
        }
        .sheet(isPresented: $state.device.showDeviceInfo) {
            NavigationStack {
                DeviceInfoView(state: state)
            }
        }
    }

    private var libraryHeader: some View {
        Text("Library")
    }

    private func commitRename(oldName: String) {
        let newName = renameText.trimmingCharacters(in: .whitespaces)
        renamingFolder = nil
        guard !newName.isEmpty, newName != oldName else { return }
        Task {
            await state.renameFolder(from: oldName, to: newName)
        }
    }

    // MARK: - Device Status Bar

    @ViewBuilder
    private var deviceStatusBar: some View {
        if state.device.isConnected, let device = state.device.model {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                        .accessibilityLabel("Connected")
                    Text("HiDock \(device.model.rawValue)")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Button {
                        state.device.showDeviceInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Device Info")
                }

                if let battery = device.battery {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: battery.isCharging ? "bolt.fill" : "battery.100")
                                .font(.caption2).foregroundStyle(DeviceColors.batteryColor(battery.level))
                            Text("Battery").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(battery.level)%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(battery.level), total: 100)
                            .tint(DeviceColors.batteryColor(battery.level)).controlSize(.small)
                            .accessibilityLabel("Battery level")
                            .accessibilityValue("\(battery.level) percent")
                    }
                }

                if let card = device.cardInfo, card.isInserted {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: "internaldrive")
                                .font(.caption2).foregroundStyle(DeviceColors.storageColor(card.usagePercent))
                            Text("Storage").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            let freeGB = Double(card.freeBytes) / 1_073_741_824
                            let totalGB = Double(card.totalBytes) / 1_073_741_824
                            Text(String(format: "%.1f / %.1f GB", freeGB, totalGB))
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        ProgressView(value: card.usagePercent, total: 100)
                            .tint(DeviceColors.storageColor(card.usagePercent)).controlSize(.small)
                            .accessibilityLabel("Storage used")
                            .accessibilityValue(String(format: "%.0f percent", card.usagePercent))
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        } else {
            HStack(spacing: 6) {
                Circle().fill(.secondary.opacity(0.5)).frame(width: 8, height: 8)
                    .accessibilityLabel("Disconnected")
                Text("No device connected").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

}
