// © 2026 High Gain Design. All rights reserved.

import SwiftUI
import HiDockKit

struct SettingsView: View {
    @Bindable var state: AppState
    @State private var storageMode: StorageMode = .icloud
    @State private var showLocationChangedAlert = false

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("General", systemImage: "gear") }

            AISettingsView()
                .tabItem { Label("AI", systemImage: "sparkles") }

            TemplateSettingsView(state: state)
                .tabItem { Label("Templates", systemImage: "doc.plaintext") }

            if let device = state.device.model, let settings = device.settings {
                deviceSettings(settings)
                    .tabItem { Label("Device", systemImage: "waveform") }
            }

            aboutView
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 450)
        .onAppear {
            let raw = UserDefaults.standard.string(forKey: "storageMode") ?? "icloud"
            storageMode = StorageMode(rawValue: raw) ?? .icloud
        }
        .alert("Storage Location Changed", isPresented: $showLocationChangedAlert) {
            Button("OK") {}
        } message: {
            Text("DockTape will now look for recordings in the new location. Your existing recordings are not moved — use Finder to move them if needed.")
        }
    }

    private var generalSettings: some View {
        Form {
            Section("Sync") {
                Toggle("Auto-sync clock on connect", isOn: $state.autoSyncClock)
                Toggle("Auto-delete from device after download", isOn: $state.autoDeleteAfterDownload)
            }

            Section("Storage Location") {
                Picker("Store recordings in", selection: $storageMode) {
                    Text("iCloud Drive").tag(StorageMode.icloud)
                    Text("This Mac").tag(StorageMode.local)
                    Text("Custom Folder\u{2026}").tag(StorageMode.custom)
                }
                .disabled(isProcessing)
                .onChange(of: storageMode) { _, newMode in
                    handleStorageModeChange(newMode)
                }

                if isProcessing {
                    Label("Can't change while processing is in progress.", systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if state.isICloudUnavailable {
                    Label("iCloud Drive is not available. Using local storage.", systemImage: "exclamationmark.icloud")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text(state.library.store.baseDirectory.path(percentEncoded: false))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Section("Shared Library") {
                sharedLibrarySettings
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var sharedLibrarySettings: some View {
        switch state.sharedLibrary.phase {
        case .legacy:
            Button("Enable Shared Library") { Task { _ = await state.enableSharedLibrary() } }
                .disabled(isProcessing)
            Text("Use a DockTape build with shared-library support on every Mac sharing this folder. Recordings stay in place.")
                .font(.caption).foregroundStyle(.secondary)
        case .connecting:
            HStack { ProgressView().controlSize(.small); Text("Opening shared library…") }
        case .ready:
            Label("Shared library enabled", systemImage: "checkmark.circle")
            Text("Independent edits are combined. Audio deletion waits for all participating Macs.")
                .font(.caption).foregroundStyle(.secondary)
        case .readOnly:
            Label("Read-only on this Mac", systemImage: "lock")
            Button("Join Shared Library") {
                Task {
                    do { try await state.sharedLibrary.requestAccess(); await state.refreshAll() }
                    catch { state.sharedLibrary.message = error.localizedDescription }
                }
            }.disabled(isProcessing)
            Text("Keep the other participating Macs running until this Mac is ready to make changes.")
                .font(.caption).foregroundStyle(.secondary)
        case .failed:
            Button("Retry Shared Library") {
                Task {
                    do { try await state.setup() }
                    catch { state.sharedLibrary.message = error.localizedDescription }
                }
            }.disabled(isProcessing)
        }
        if let message = state.sharedLibrary.message { Text(message).font(.caption).foregroundStyle(.red) }
        Text("For Dropbox, choose a folder managed by its desktop app. Readable transcripts and summaries stay alongside the recordings.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func deviceSettings(_ settings: DeviceSettings) -> some View {
        Form {
            DeviceSettingsSection(settings: settings) { updated in
                Task { await state.updateDeviceSettings(updated) }
            }
        }
        .formStyle(.grouped)
    }

    private var aboutView: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("DockTape")
                .font(.title.bold())
            Text("HiDock Manager")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("Import HiDock recordings and transcribe and diarize on-device. Summaries use your chosen local or cloud provider.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            Spacer().frame(height: 8)

            Text("© 2026 High Gain Design. All rights reserved.")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isProcessing: Bool {
        state.transcription.isTranscribing || state.summarization.isSummarizing || state.device.isDeviceBusy || state.sharedLibrary.isBusy
    }

    private func handleStorageModeChange(_ mode: StorageMode) {
        if mode == .custom {
            chooseCustomLocation()
        } else {
            Task {
                showLocationChangedAlert = await state.switchStorageLocation(to: mode)
                if !showLocationChangedAlert {
                    let raw = UserDefaults.standard.string(forKey: "storageMode") ?? "icloud"
                    storageMode = StorageMode(rawValue: raw) ?? .icloud
                }
            }
        }
    }

    private func chooseCustomLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Select where to store downloaded recordings"

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                showLocationChangedAlert = await state.switchStorageLocation(to: .custom, customURL: url)
                if !showLocationChangedAlert {
                    let raw = UserDefaults.standard.string(forKey: "storageMode") ?? "icloud"
                    storageMode = StorageMode(rawValue: raw) ?? .icloud
                }
            }
        } else {
            // User cancelled — revert picker to previous mode
            let raw = UserDefaults.standard.string(forKey: "storageMode") ?? "icloud"
            storageMode = StorageMode(rawValue: raw) ?? .icloud
        }
    }
}
