import SwiftUI
import HiDockKit

struct SettingsView: View {
    @Bindable var state: AppState
    @AppStorage("libraryLocation") private var libraryLocationBookmark: Data?
    @State private var libraryPath: String = ""
    @State private var showRestartAlert = false

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("General", systemImage: "gear") }

            if let device = state.device.model, let settings = device.settings {
                deviceSettings(settings)
                    .tabItem { Label("Device", systemImage: "waveform") }
            }

            aboutView
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 450)
        .onAppear {
            libraryPath = state.library.store.baseDirectory.path(percentEncoded: false)
        }
        .alert("Restart Required", isPresented: $showRestartAlert) {
            Button("OK") {}
        } message: {
            Text("The library location will change when you restart the app.")
        }
    }

    private var generalSettings: some View {
        Form {
            Section("Sync") {
                Toggle("Auto-sync clock on connect", isOn: $state.autoSyncClock)
                Toggle("Auto-delete from device after download", isOn: $state.autoDeleteAfterDownload)
            }

            Section("Library Location") {
                HStack {
                    Text(libraryPath)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Change...") {
                        chooseLibraryLocation()
                    }

                    if libraryLocationBookmark != nil {
                        Button("Reset") {
                            libraryLocationBookmark = nil
                            libraryPath = defaultLibraryPath
                            showRestartAlert = true
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func deviceSettings(_ settings: DeviceSettings) -> some View {
        Form {
            Section("Device Settings") {
                Toggle("Auto-record on power", isOn: Binding(
                    get: { settings.autoRecord },
                    set: { newValue in
                        var updated = settings
                        updated.autoRecord = newValue
                        Task { await state.updateDeviceSettings(updated) }
                    }
                ))
                Toggle("Auto-play on connect", isOn: Binding(
                    get: { settings.autoPlay },
                    set: { newValue in
                        var updated = settings
                        updated.autoPlay = newValue
                        Task { await state.updateDeviceSettings(updated) }
                    }
                ))
                Toggle("Notification sounds", isOn: Binding(
                    get: { settings.notification },
                    set: { newValue in
                        var updated = settings
                        updated.notification = newValue
                        Task { await state.updateDeviceSettings(updated) }
                    }
                ))
            }
        }
        .formStyle(.grouped)
    }

    private var aboutView: some View {
        VStack(spacing: 12) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
            Text("DockTape")
                .font(.title.bold())
            Text("HiDock Manager")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Download, transcribe, and manage recordings from your HiDock device.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseLibraryLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Select where to store downloaded recordings"

        if panel.runModal() == .OK, let url = panel.url {
            // Store as security-scoped bookmark so we can access it after restart
            if let bookmark = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                libraryLocationBookmark = bookmark
                libraryPath = url.path(percentEncoded: false)
                // Also store the plain URL for AppState init
                UserDefaults.standard.set(url, forKey: "libraryLocation")
                showRestartAlert = true
            }
        }
    }

    private var defaultLibraryPath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("HiDock Recordings").path(percentEncoded: false)
    }
}
