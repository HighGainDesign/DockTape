import SwiftUI
import AppKit
import HiDockKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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

    var body: some Commands {
        // Navigation
        CommandGroup(after: .sidebar) {
            Button("Show Library") {
                state?.selectedView = .library
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Show Device") {
                guard state?.isConnected == true else { return }
                state?.selectedView = .onDevice
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(state?.isConnected != true)

            Divider()

            Button("Get Info") {
                state?.showDeviceInfo = true
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(state?.isConnected != true)

            Divider()
        }

        // Search — Cmd+F to focus search field
        CommandGroup(replacing: .textEditing) {
            Button("Find") {
                state?.isSearchFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)

            Divider()
        }

        // Playback
        CommandGroup(after: .textEditing) {
            Button(state?.isPlaying == true ? "Pause" : "Play") {
                state?.togglePlayPause()
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(state?.playingFile == nil)

            Button("Stop") {
                state?.stopPlayback()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(state?.playingFile == nil)

            Divider()

            Button("Increase Speed") {
                guard let state else { return }
                let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]
                if let idx = speeds.firstIndex(of: state.playbackRate), idx + 1 < speeds.count {
                    state.setPlaybackRate(speeds[idx + 1])
                }
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(state?.playingFile == nil)

            Button("Decrease Speed") {
                guard let state else { return }
                let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]
                if let idx = speeds.firstIndex(of: state.playbackRate), idx > 0 {
                    state.setPlaybackRate(speeds[idx - 1])
                }
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(state?.playingFile == nil)

            Button("Reset Speed") {
                state?.setPlaybackRate(1.0)
            }
            .keyboardShortcut("\\", modifiers: .command)
            .disabled(state?.playingFile == nil)

            Divider()
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
        .defaultSize(width: 900, height: 600)
        .commands {
            AppCommands()
            // Remove New Window / New Tab — single-window app
            CommandGroup(replacing: .newItem) {}
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
