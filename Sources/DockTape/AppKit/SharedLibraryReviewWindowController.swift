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
            TabView(selection: Binding(get: { state.sharedLibrary.reviewTab }, set: { state.sharedLibrary.reviewTab = $0 })) {
                SharedLibraryReviewView(state: state, onClose: { [weak window] in window?.close() })
                    .tabItem { Text("Competing Edits") }
                    .tag(SharedLibraryState.ReviewTab.competingEdits)
                PendingRecordingFilesView(state: state, onClose: { [weak window] in window?.close() })
                    .tabItem { Text("Pending Files") }
                    .tag(SharedLibraryState.ReviewTab.pendingFiles)
                ExternalSidecarReviewView(state: state, onClose: { [weak window] in window?.close() })
                    .tabItem { Text("External Files") }
                    .tag(SharedLibraryState.ReviewTab.externalFiles)
            })
        window.setFrameAutosaveName("SharedLibraryReview")
        window.center()
        super.init(window: window)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
