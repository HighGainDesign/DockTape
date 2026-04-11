// © 2026 High Gain Design. All rights reserved.

import AppKit
import SwiftUI
import HiDockKit

final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    init(appState: AppState) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()

        super.init()

        statusItem.button?.image = NSImage(systemSymbolName: "cable.connector.horizontal", accessibilityDescription: "DockTape")
        popover.contentSize = NSSize(width: 220, height: 200)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarView(state: appState))

        statusItem.button?.action = #selector(togglePopover(_:))
        statusItem.button?.target = self
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
