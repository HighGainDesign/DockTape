import SwiftUI

/// Shared color helpers for device battery and storage indicators.
enum DeviceColors {
    static func batteryColor(_ level: Int) -> Color {
        switch level {
        case 51...100: .green
        case 21...50: .yellow
        default: .red
        }
    }

    static func storageColor(_ percent: Double) -> Color {
        switch percent {
        case 90...: .red
        case 75..<90: .orange
        default: .green
        }
    }

    /// Dynamic SF Symbol name for a battery level and charging state.
    static func batteryIcon(level: Int, isCharging: Bool) -> String {
        if isCharging { return "battery.100.bolt" }
        switch level {
        case 76...100: return "battery.100"
        case 51...75: return "battery.75"
        case 26...50: return "battery.50"
        default: return "battery.25"
        }
    }
}
