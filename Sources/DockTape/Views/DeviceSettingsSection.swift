import SwiftUI
import HiDockKit

/// Shared device settings toggle section used in both DeviceInfoView and SettingsView.
struct DeviceSettingsSection: View {
    let settings: DeviceSettings
    let onUpdate: (DeviceSettings) -> Void

    var body: some View {
        Section("Device Settings") {
            Toggle("Auto-record on power", isOn: Binding(
                get: { settings.autoRecord },
                set: { newValue in
                    var updated = settings
                    updated.autoRecord = newValue
                    onUpdate(updated)
                }
            ))
            Toggle("Auto-play on connect", isOn: Binding(
                get: { settings.autoPlay },
                set: { newValue in
                    var updated = settings
                    updated.autoPlay = newValue
                    onUpdate(updated)
                }
            ))
            Toggle("Notification sounds", isOn: Binding(
                get: { settings.notification },
                set: { newValue in
                    var updated = settings
                    updated.notification = newValue
                    onUpdate(updated)
                }
            ))
        }
    }
}
