import SwiftUI

/// Toolbar button with icon + text label, bordered style.
@ViewBuilder
func toolbarButton(_ systemImage: String, _ label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Label(label, systemImage: systemImage)
            .font(.caption)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .fixedSize()
    .help(label)
}
