// © 2026 High Gain Design. All rights reserved.

import SwiftUI
import HiDockKit

struct MenuBarView: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.device.isConnected, let device = state.device.model {
                Label(device.model.rawValue, systemImage: "cable.connector.horizontal")
                    .font(.headline)

                if let battery = device.battery {
                    HStack {
                        Image(systemName: DeviceColors.batteryIcon(level: battery.level, isCharging: battery.isCharging))
                            .foregroundStyle(DeviceColors.batteryColor(battery.level))
                        Text("\(battery.level)%")
                    }
                }

                Divider()

                Text("\(device.files.count) recordings on device")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Open DockTape") {
                    if #available(macOS 14.0, *) {
                        NSApp.activate()
                    } else {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    // Prefer the key window, then the main window, then any orderable window
                    let window = NSApp.keyWindow
                        ?? NSApp.mainWindow
                        ?? NSApp.windows.first { $0.canBecomeKey && !$0.isKind(of: NSPanel.self) }
                    window?.makeKeyAndOrderFront(nil)
                }
            } else {
                Label("No Device", systemImage: "cable.connector.horizontal")
                    .foregroundStyle(.secondary)

                Text("Connect a HiDock device via USB")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            Button("Quit DockTape") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 220)
    }
}
