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
}
