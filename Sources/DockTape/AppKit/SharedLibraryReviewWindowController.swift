// © 2026 High Gain Design. All rights reserved.
import AppKit
import SwiftUI

@MainActor final class SharedLibraryReviewWindowController: NSWindowController {
    init(state: AppState) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Shared Library Review"
        window.contentMinSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView:
            SharedLibraryReviewTabs(appState: state, state: state.sharedLibrary,
                onClose: { [weak window] in window?.close() }))
        window.setFrameAutosaveName("SharedLibraryReview")
        window.center()
        super.init(window: window)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// Keep selection in a View body so external review-tab changes participate in
/// SwiftUI observation as well as updating the native tab selector.
private struct SharedLibraryReviewTabs: View {
    let appState: AppState
    @Bindable var state: SharedLibraryState
    let onClose: () -> Void

    var body: some View {
        TabView(selection: $state.reviewTab) {
            SharedLibraryReviewView(state: appState, onClose: onClose)
                .tabItem { Text("Competing Edits") }
                .tag(SharedLibraryState.ReviewTab.competingEdits)
            PendingRecordingFilesView(state: appState, onClose: onClose)
                .tabItem { Text("Pending Files") }
                .tag(SharedLibraryState.ReviewTab.pendingFiles)
            PendingFolderFilesView(state: appState, onClose: onClose)
                .tabItem { Text("Pending Folders") }
                .tag(SharedLibraryState.ReviewTab.pendingFolders)
            ExternalSidecarReviewView(state: appState, onClose: onClose)
                .tabItem { Text("External Files") }
                .tag(SharedLibraryState.ReviewTab.externalFiles)
        }
    }
}
