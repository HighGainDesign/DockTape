import SwiftUI
import HiDockKit

struct ContentView: View {
    @Bindable var state: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView(state: state)
        } content: {
            RecordingListPane(state: state)
        } detail: {
            DetailPane(state: state)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        .navigationTitle("")
        .frame(minWidth: 960, minHeight: 560)
        .focusedSceneValue(\.appState, state)
        .sheet(isPresented: $state.device.showDeviceInfo) {
            NavigationStack {
                DeviceInfoView(state: state)
            }
        }
        .alert("Error", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("Dismiss", role: .cancel) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }
}

// MARK: - Search Focus Modifier (macOS 15+ conditional)

struct SearchFocusModifier: ViewModifier {
    @Binding var trigger: Bool
    @FocusState private var isSearchFocused: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .searchFocused($isSearchFocused)
                .onChange(of: trigger) { _, focused in
                    if focused {
                        isSearchFocused = true
                        trigger = false
                    }
                }
        } else {
            content
        }
    }
}
