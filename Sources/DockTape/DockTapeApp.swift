import SwiftUI
import AppKit
import HiDockKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Focused Value for AppState

struct AppStateFocusedKey: FocusedValueKey {
    typealias Value = AppState
}

extension FocusedValues {
    var appState: AppState? {
        get { self[AppStateFocusedKey.self] }
        set { self[AppStateFocusedKey.self] = newValue }
    }
}

// MARK: - App Commands

struct AppCommands: Commands {
    @FocusedValue(\.appState) var state

    private var hasSelection: Bool {
        !(state?.library.selectedRecordings.isEmpty ?? true)
    }

    private var selectedRecordings: [RecordingMetadata] {
        guard let state else { return [] }
        return state.library.recordings.filter { state.library.selectedRecordings.contains($0.filename) }
    }

    var body: some Commands {
        // File menu — recording-level actions
        CommandGroup(replacing: .newItem) {
            Button("Transcribe") {
                guard let state else { return }
                let toTranscribe = selectedRecordings.filter {
                    (state.transcription.statuses[$0.filename] ?? .none) != .done
                }
                guard !toTranscribe.isEmpty else { return }
                Task { await state.transcribeRecordings(toTranscribe) }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(!hasSelection)

            Button("Summarize") {
                guard let state, let rec = selectedRecordings.first else { return }
                state.contextMenuSummarize(rec)
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(!hasSelection || selectedRecordings.allSatisfy {
                (state?.transcription.statuses[$0.filename] ?? .none) != .done
            })

            Divider()

            Button("Reveal in Finder") {
                guard let state, let rec = selectedRecordings.first else { return }
                state.library.revealInFinder(rec)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!hasSelection)

            Divider()

            Button("Delete") {
                guard let state else { return }
                Task {
                    for rec in selectedRecordings {
                        await state.deleteLocalRecording(rec)
                    }
                    state.library.selectedRecordings.removeAll()
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!hasSelection)
        }

        // Edit menu — just search
        CommandGroup(replacing: .textEditing) {
            Button("Find") {
                state?.library.isSearchFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)

            Divider()
        }

        // View menu — navigation
        CommandGroup(after: .sidebar) {
            Button("Show All Recordings") {
                state?.selectedView = .allRecordings
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Show Device") {
                guard state?.device.isConnected == true else { return }
                state?.selectedView = .device
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(state?.device.isConnected != true)

            Divider()
        }

        // Playback menu
        CommandMenu("Playback") {
            Button(state?.playback.isPlaying == true ? "Pause" : "Play") {
                guard let state else { return }
                if state.playback.playingFile != nil {
                    state.playback.togglePlayPause()
                } else if state.library.selectedRecordings.count == 1,
                          let filename = state.library.selectedRecordings.first,
                          let rec = state.library.recordings.first(where: { $0.filename == filename }) {
                    state.playRecording(rec)
                }
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(state?.playback.playingFile == nil && state?.library.selectedRecordings.count != 1)

            Button("Stop") {
                state?.playback.stop()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(state?.playback.playingFile == nil)

            Divider()

            Button("Increase Speed") {
                guard let state else { return }
                let speeds = PlaybackState.speeds
                if let idx = speeds.firstIndex(of: state.playback.rate), idx + 1 < speeds.count {
                    state.playback.setRate(speeds[idx + 1])
                }
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(state?.playback.playingFile == nil)

            Button("Decrease Speed") {
                guard let state else { return }
                let speeds = PlaybackState.speeds
                if let idx = speeds.firstIndex(of: state.playback.rate), idx > 0 {
                    state.playback.setRate(speeds[idx - 1])
                }
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(state?.playback.playingFile == nil)

            Button("Reset Speed") {
                state?.playback.setRate(1.0)
            }
            .keyboardShortcut("\\", modifiers: .command)
            .disabled(state?.playback.playingFile == nil)
        }

        // Device menu
        CommandMenu("Device") {
            Button("Sync All") {
                guard let state else { return }
                Task { await state.syncAll() }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(state?.device.isConnected != true || state?.device.isSyncing == true)

            Button("Refresh Device") {
                guard let state else { return }
                Task { await state.device.refreshDevice() }
            }
            .disabled(state?.device.isConnected != true)

            Divider()

            Button("Device Info...") {
                state?.device.showDeviceInfo = true
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(state?.device.isConnected != true)
        }
    }
}

@main
struct DockTapeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var appState = AppState()

    var body: some Scene {
        Window("DockTape", id: "main") {
            ContentView(state: appState)
                .task {
                    do {
                        try await appState.setup()
                        appState.startMonitoring()
                    } catch {
                        appState.statusMessage = "Storage error: \(error.localizedDescription)"
                    }
                }
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            AppCommands()
        }

        Settings {
            SettingsView(state: appState)
        }

        MenuBarExtra("DockTape", systemImage: "cable.connector.horizontal") {
            MenuBarView(state: appState)
        }
        .menuBarExtraStyle(.window)
    }
}
