import SwiftUI
import HiDockKit

struct MenuBarView: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.isConnected, let device = state.device {
                Label(device.model.rawValue, systemImage: "cable.connector.horizontal")
                    .font(.headline)

                if let battery = device.battery {
                    HStack {
                        Image(systemName: battery.isCharging ? "battery.100.bolt" : "battery.75")
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
                    NSApp.windows.first { $0.isVisible || $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
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
