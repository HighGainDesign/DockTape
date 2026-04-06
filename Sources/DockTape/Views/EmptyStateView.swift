import SwiftUI

struct EmptyStateView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Connect Your HiDock", systemImage: "cable.connector.horizontal")
        } description: {
            Text("Plug in your HiDock P1, P1 Mini, H1, or H1E via USB to get started.")
        } actions: {
            Link("HiDock Support", destination: URL(string: "https://www.hidock.com/support")!)
                .buttonStyle(.bordered)
        }
    }
}
