// © 2026 High Gain Design. All rights reserved.

import AppKit
import SwiftUI
import HiDockKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    var mainWindowController: MainWindowController?
    var statusBarController: StatusBarController?

    static func main() {
        // Sync iCloud settings before AppState reads them
        SyncedDefaults.shared.start()

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = MainMenu.build(appState: appState)
        let wc = MainWindowController(appState: appState)
        wc.showWindow(nil)
        mainWindowController = wc
        statusBarController = StatusBarController(appState: appState)
        Task { @MainActor in
            do {
                try await appState.setup()
                appState.startMonitoring()
            } catch {
                appState.statusMessage = "Storage error: \(error.localizedDescription)"
            }

            if appState.showMigrationPrompt {
                appState.showMigrationPrompt = false
                showMigrationAlert()
            }
        }
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindowController?.showWindow(nil) }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in await appState.refreshAll() }
    }

    private func showMigrationAlert() {
        let alert = NSAlert()
        alert.messageText = "DockTape Now Uses iCloud Drive"
        alert.informativeText = "Your recordings are now stored in iCloud Drive so they sync across your devices.\n\nYou have existing recordings in ~/Documents/HiDock Recordings/. To access them in DockTape, move them to the iCloud Drive folder using Finder.\n\nYou can change the storage location in Settings → General."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open in Finder")
        alert.addButton(withTitle: "OK")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Open both folders in Finder
            let local = StorageLocationResolver.localDefault
            let icloud = StorageLocationResolver.resolve(mode: .icloud, customURL: nil)
            NSWorkspace.shared.activateFileViewerSelecting([local, icloud])
        }
    }
}
