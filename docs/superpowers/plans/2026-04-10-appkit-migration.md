# AppKit Window Host Migration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the SwiftUI NavigationSplitView + safeAreaInset toolbar workaround with a proper AppKit shell using NSSplitViewController + NSToolbar + NSTrackingSeparatorToolbarItem, matching Apple Notes/Mail layout. Enable playback progress and transcript highlighting.

**Architecture:** Full AppKit window shell. `@main` moves to an NSApplicationDelegate. Three SwiftUI views (sidebar, recording list, detail) are hosted in NSHostingControllers inside NSSplitViewItems. NSToolbar spans only the detail pane (right of the tracking separator). State layer (AppState + sub-states) is unchanged.

**Tech Stack:** Swift 5.10+, AppKit (NSWindow, NSSplitViewController, NSToolbar, NSTrackingSeparatorToolbarItem), SwiftUI (hosted views), AVFoundation (playback progress)

**Spec:** `docs/superpowers/specs/2026-04-10-appkit-migration-design.md`

---

## File Structure

### New files

| File | Responsibility |
|------|---------------|
| `Sources/DockTape/AppKit/AppDelegate.swift` | `@main`, NSApplicationDelegate, owns AppState, creates window + status bar |
| `Sources/DockTape/AppKit/MainWindowController.swift` | NSWindowController, NSToolbarDelegate, toolbar item creation + validation |
| `Sources/DockTape/AppKit/MainSplitViewController.swift` | NSSplitViewController with 3 NSSplitViewItems hosting SwiftUI views |
| `Sources/DockTape/AppKit/MainMenu.swift` | NSMenu builder — all menus + keyboard shortcuts |
| `Sources/DockTape/AppKit/StatusBarController.swift` | NSStatusItem + NSPopover hosting MenuBarView |

### Deleted files

| File | Reason |
|------|--------|
| `Sources/DockTape/DockTapeApp.swift` | Replaced by AppDelegate.swift (entry point, commands, scenes) |
| `Sources/DockTape/Views/ContentView.swift` | NavigationSplitView wrapper — layout now handled by NSSplitViewController |

### Modified files

| File | Changes |
|------|---------|
| `Sources/DockTape/AppState.swift` | Move `DetailTab` enum here (from DetailPane). Remove `FocusedValueKey` (no longer needed). |
| `Sources/DockTape/Views/RecordingListPane.swift` | Remove `safeAreaInset` toolbars (lines 64, 144). Remove Import/Delete buttons. Keep sort/filter as in-view header. Add folder name header. |
| `Sources/DockTape/Views/DetailPane.swift` | Remove inline toolbar (lines 98-162). Remove action buttons (moved to NSToolbar). Keep tabs, alerts, sheets. Restructure Now Playing to pin at bottom. |
| `Sources/DockTape/Views/SidebarView.swift` | Change `plus` icon to `folder.badge.plus` (line 147). Remove `onReceive(didBecomeActive)` (moved to AppDelegate). |
| `Sources/DockTape/Views/MultiSelectSummary.swift` | Remove action buttons (Transcribe/Delete) — actions now in NSToolbar. Keep stats display. |
| `Sources/DockTape/Views/ToolbarButton.swift` | Keep — still used for in-view buttons (sort/filter). |
| `Sources/DockTape/State/PlaybackState.swift` | Add periodic time observer, App Nap activity token, activeSegmentIndex update. |
| `Sources/DockTape/Views/TranscriptViewer.swift` | Add segment highlighting style when `activeSegmentIndex` matches. Add auto-scroll via ScrollViewReader. |

---

## Task 1: Create AppDelegate + Main Entry Point

**Files:**
- Create: `Sources/DockTape/AppKit/AppDelegate.swift`
- Delete: `Sources/DockTape/DockTapeApp.swift` (but only after Task 6 replaces all its functionality)

This task creates the new entry point. DockTapeApp.swift is NOT deleted yet — we'll have a temporary compile error from two `@main` annotations, resolved by removing the old one at the end of this task.

- [ ] **Step 1: Create AppKit directory**

```bash
mkdir -p Sources/DockTape/AppKit
```

- [ ] **Step 2: Write AppDelegate.swift**

```swift
// Sources/DockTape/AppKit/AppDelegate.swift
import AppKit
import SwiftUI
import HiDockKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    var mainWindowController: MainWindowController?
    var statusBarController: StatusBarController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // Main menu
        NSApp.mainMenu = MainMenu.build(appState: appState)

        // Main window
        let wc = MainWindowController(appState: appState)
        wc.showWindow(nil)
        mainWindowController = wc

        // Status bar (menu bar extra)
        statusBarController = StatusBarController(appState: appState)

        // Initialize app state
        Task { @MainActor in
            do {
                try await appState.setup()
                appState.startMonitoring()
            } catch {
                appState.statusMessage = "Storage error: \(error.localizedDescription)"
            }
        }

        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            mainWindowController?.showWindow(nil)
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            await appState.refreshAll()
        }
    }
}
```

- [ ] **Step 3: Remove `@main` from DockTapeApp.swift**

Remove lines 242-273 from `DockTapeApp.swift` (the entire `@main struct DockTapeApp: App { ... }` block). Keep `AppStateFocusedKey`, `AppCommands` for now — they'll be removed in Task 6.

Also remove lines 1-14 (the old `AppDelegate` class) since the new one replaces it.

- [ ] **Step 4: Build to verify no duplicate @main**

```bash
cd /Users/anand/Library/CloudStorage/Dropbox/src/vibe/docktape && swift build 2>&1 | head -20
```

Expected: Compile errors for missing `MainWindowController`, `MainMenu`, `StatusBarController` — that's fine. No "duplicate @main" error.

---

## Task 2: Create MainSplitViewController

**Files:**
- Create: `Sources/DockTape/AppKit/MainSplitViewController.swift`

- [ ] **Step 1: Write MainSplitViewController.swift**

```swift
// Sources/DockTape/AppKit/MainSplitViewController.swift
import AppKit
import SwiftUI
import HiDockKit

final class MainSplitViewController: NSSplitViewController {
    let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Sidebar — full-height, extends into titlebar
        let sidebarHost = NSHostingController(rootView: SidebarView(state: appState))
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 280
        addSplitViewItem(sidebarItem)

        // Content list
        let listHost = NSHostingController(rootView: RecordingListPane(state: appState))
        let listItem = NSSplitViewItem(contentListWithViewController: listHost)
        listItem.minimumThickness = 280
        addSplitViewItem(listItem)

        // Detail pane
        let detailHost = NSHostingController(rootView: DetailPane(state: appState))
        let detailItem = NSSplitViewItem(viewController: detailHost)
        detailItem.minimumThickness = 360
        addSplitViewItem(detailItem)

        splitView.dividerStyle = .thin
    }
}
```

- [ ] **Step 2: Verify the file compiles in isolation**

No build yet — MainWindowController is still missing. Just verify no syntax errors:

```bash
cd /Users/anand/Library/CloudStorage/Dropbox/src/vibe/docktape && swiftc -typecheck -target arm64-apple-macos14.0 -import-objc-header /dev/null Sources/DockTape/AppKit/MainSplitViewController.swift 2>&1 | head -5
```

This may fail on imports — that's OK. We'll do a full build after Task 3.

---

## Task 3: Create MainWindowController + NSToolbar

**Files:**
- Create: `Sources/DockTape/AppKit/MainWindowController.swift`

- [ ] **Step 1: Write MainWindowController.swift**

```swift
// Sources/DockTape/AppKit/MainWindowController.swift
import AppKit
import SwiftUI
import HiDockKit

// MARK: - Toolbar Item Identifiers

private extension NSToolbarItem.Identifier {
    static let trackingSeparator = NSToolbarItem.Identifier("trackingSeparator")
    static let playPause = NSToolbarItem.Identifier("playPause")
    static let transcribe = NSToolbarItem.Identifier("transcribe")
    static let summarize = NSToolbarItem.Identifier("summarize")
    static let importFile = NSToolbarItem.Identifier("importFile")
    static let delete = NSToolbarItem.Identifier("delete")
    static let refresh = NSToolbarItem.Identifier("refresh")
    static let search = NSToolbarItem.Identifier("search")
}

final class MainWindowController: NSWindowController, NSToolbarDelegate {
    let appState: AppState
    private let splitViewController: MainSplitViewController
    private var stateObservationTask: Task<Void, Never>?
    private var searchField: NSSearchField?

    // Track which items are currently visible for context switching
    private var isDeviceContext: Bool = false

    init(appState: AppState) {
        self.appState = appState
        self.splitViewController = MainSplitViewController(appState: appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "DockTape"
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .hidden
        window.setFrameAutosaveName("MainWindow")
        window.minSize = NSSize(width: 960, height: 560)
        window.contentViewController = splitViewController

        // Full-height sidebar style
        window.titlebarSeparatorStyle = .automatic

        super.init(window: window)

        setupToolbar()
        startObservingState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        stateObservationTask?.cancel()
    }

    // MARK: - Toolbar Setup

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .trackingSeparator:
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: splitViewController.splitView,
                dividerIndex: 1 // between content list and detail
            )

        case .playPause:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Play"
            item.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
            item.target = self
            item.action = #selector(playPause(_:))
            item.toolTip = "Play or pause the selected recording"
            item.isBordered = true
            return item

        case .transcribe:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Transcribe"
            item.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: "Transcribe")
            item.target = self
            item.action = #selector(transcribeAction(_:))
            item.toolTip = "Transcribe selected recording(s)"
            item.isBordered = true
            return item

        case .summarize:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Summarize"
            item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Summarize")
            item.toolTip = "Summarize with template"
            item.isBordered = true
            item.menu = buildSummarizeMenu()
            item.showsIndicator = true
            return item

        case .importFile:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Import"
            item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Import")
            item.target = self
            item.action = #selector(importAction(_:))
            item.toolTip = "Import selected file(s) from device"
            item.isBordered = true
            return item

        case .delete:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Delete"
            item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
            item.target = self
            item.action = #selector(deleteAction(_:))
            item.toolTip = "Delete selected item(s)"
            item.isBordered = true
            return item

        case .refresh:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Refresh"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
            item.target = self
            item.action = #selector(refreshAction(_:))
            item.toolTip = "Refresh from disk or device"
            item.isBordered = true
            return item

        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField.placeholderString = "Search"
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            searchField = item.searchField
            return item

        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            .toggleSidebar,
            .trackingSeparator,
            .playPause,
            .transcribe,
            .summarize,
            .importFile,
            .delete,
            .refresh,
            .flexibleSpace,
            .search,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar)
    }

    // MARK: - Toolbar Validation

    override func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let isDevice = isDeviceContext
        let libraryCount = appState.library.selectedRecordings.count
        let deviceCount = appState.device.selectedDeviceFiles.count
        let hasSelection = isDevice ? deviceCount > 0 : libraryCount > 0
        let hasSingleSelection = isDevice ? deviceCount == 1 : libraryCount == 1

        switch item.itemIdentifier {
        case .playPause:
            let isPlaying = appState.playback.isPlaying
            item.label = isPlaying ? "Pause" : "Play"
            item.image = NSImage(
                systemSymbolName: isPlaying ? "pause.fill" : "play.fill",
                accessibilityDescription: isPlaying ? "Pause" : "Play"
            )
            // Play only in library context with single selection (or if already playing)
            return !isDevice && (hasSingleSelection || appState.playback.playingFile != nil)

        case .transcribe:
            item.isHidden = isDevice
            return !isDevice && hasSelection

        case .summarize:
            item.isHidden = isDevice
            if !isDevice && hasSelection {
                // Check if any selected recording has a transcript
                let recs = appState.library.recordings.filter { appState.library.selectedRecordings.contains($0.filename) }
                return recs.contains { (appState.transcription.statuses[$0.filename] ?? .none) == .done }
            }
            return false

        case .importFile:
            item.isHidden = !isDevice
            return isDevice && hasSelection

        case .delete:
            return hasSelection

        case .refresh:
            return true

        default:
            return true
        }
    }

    // MARK: - Toolbar Actions

    @objc private func playPause(_ sender: Any?) {
        if appState.playback.playingFile != nil {
            appState.playback.togglePlayPause()
        } else if appState.library.selectedRecordings.count == 1,
                  let filename = appState.library.selectedRecordings.first,
                  let rec = appState.library.recordings.first(where: { $0.filename == filename }) {
            appState.playRecording(rec)
        }
    }

    @objc private func transcribeAction(_ sender: Any?) {
        let recs = selectedLibraryRecordings.filter {
            (appState.transcription.statuses[$0.filename] ?? .none) != .done
        }
        guard !recs.isEmpty else { return }
        Task { await appState.transcribeRecordings(recs) }
    }

    @objc private func importAction(_ sender: Any?) {
        let files = appState.device.files.filter { appState.device.selectedDeviceFiles.contains($0.filename) }
        Task {
            for file in files { await appState.downloadFile(file) }
        }
    }

    @objc private func deleteAction(_ sender: Any?) {
        if isDeviceContext {
            let files = appState.device.files.filter { appState.device.selectedDeviceFiles.contains($0.filename) }
            Task {
                for file in files { await appState.deleteFromDevice(file) }
                appState.device.selectedDeviceFiles.removeAll()
            }
        } else {
            let recs = selectedLibraryRecordings
            Task {
                for rec in recs { await appState.deleteLocalRecording(rec) }
                appState.library.selectedRecordings.removeAll()
            }
        }
    }

    @objc private func refreshAction(_ sender: Any?) {
        if isDeviceContext {
            Task { await appState.device.refreshDevice() }
        } else {
            Task { await appState.refreshAll() }
        }
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        appState.library.searchText = sender.stringValue
    }

    // MARK: - Summarize Menu

    private func buildSummarizeMenu() -> NSMenu {
        let menu = NSMenu(title: "Summarize")
        let builtIn = TemplateStore.builtInDefaults
        for template in builtIn {
            let item = NSMenuItem(title: template.name, action: #selector(summarizeWithTemplate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = template
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let customItem = NSMenuItem(title: "Custom prompt...", action: #selector(summarizeCustomPrompt(_:)), keyEquivalent: "")
        customItem.target = self
        menu.addItem(customItem)
        return menu
    }

    @objc private func summarizeWithTemplate(_ sender: NSMenuItem) {
        guard let template = sender.representedObject as? Template else { return }
        for rec in selectedLibraryRecordings {
            appState.summarizeWithTemplate(rec, template: template)
        }
    }

    @objc private func summarizeCustomPrompt(_ sender: NSMenuItem) {
        appState.triggerCustomPrompt = true
    }

    // MARK: - Helpers

    private var selectedLibraryRecordings: [RecordingMetadata] {
        appState.library.recordings.filter { appState.library.selectedRecordings.contains($0.filename) }
    }

    // MARK: - State Observation

    /// Observe AppState changes to update toolbar context and validation.
    private func startObservingState() {
        func observe() {
            withObservationTracking {
                _ = self.appState.selectedView
                _ = self.appState.library.selectedRecordings.count
                _ = self.appState.device.selectedDeviceFiles.count
                _ = self.appState.playback.isPlaying
                _ = self.appState.playback.playingFile
            } onChange: {
                Task { @MainActor [weak self] in
                    self?.updateToolbarContext()
                    observe() // re-register
                }
            }
        }

        stateObservationTask = Task { @MainActor in
            observe()
        }
    }

    private func updateToolbarContext() {
        let shouldBeDevice: Bool
        switch appState.selectedView {
        case .device: shouldBeDevice = true
        default: shouldBeDevice = false
        }

        if shouldBeDevice != isDeviceContext {
            isDeviceContext = shouldBeDevice
            // Force toolbar to re-validate all items (updates hidden/enabled state)
            window?.toolbar?.validateVisibleItems()
        } else {
            window?.toolbar?.validateVisibleItems()
        }
    }
}
```

- [ ] **Step 2: Build the project**

```bash
cd /Users/anand/Library/CloudStorage/Dropbox/src/vibe/docktape && swift build 2>&1 | tail -20
```

Expected: Errors for missing `MainMenu`, `StatusBarController`, and possibly `appState.library.searchText` (new property) and `appState.triggerCustomPrompt` (new property). These are addressed in later tasks. The structure should be sound.

---

## Task 4: Adapt AppState for AppKit Integration

**Files:**
- Modify: `Sources/DockTape/AppState.swift`

Small additions needed for the AppKit toolbar to communicate with the SwiftUI views.

- [ ] **Step 1: Move DetailTab enum to AppState.swift**

Add this near the top of `AppState.swift` (after `SidebarSelection`), since DetailPane.swift will no longer own it (it's referenced by MainMenu and MainWindowController too):

```swift
enum DetailTab: String, CaseIterable {
    case info = "Info"
    case transcript = "Transcript"
    case summary = "Summary"
}
```

- [ ] **Step 2: Add searchText to LibraryState**

In `Sources/DockTape/State/LibraryState.swift`, add a `searchText` property:

```swift
var searchText: String = ""
```

This replaces the local `@State` searchText in RecordingListPane — the NSToolbar's search field writes to it, and the SwiftUI list reads it.

- [ ] **Step 3: Add triggerCustomPrompt to AppState**

In `AppState.swift`, add alongside `triggerRename`:

```swift
var triggerCustomPrompt: Bool = false
```

- [ ] **Step 4: Update DetailPane to use AppState.DetailTab**

In `DetailPane.swift`, remove the `DetailTab` enum definition (lines 17-21) and update all references from `DetailPane.DetailTab` to `DetailTab`. The references in AppState (`selectedDetailTab`) and DockTapeApp (`AppCommands`) already use `DetailPane.DetailTab` — update those to `DetailTab`.

- [ ] **Step 5: Build to verify**

```bash
cd /Users/anand/Library/CloudStorage/Dropbox/src/vibe/docktape && swift build 2>&1 | tail -20
```

---

## Task 5: Adapt SwiftUI Views for NSHostingController

**Files:**
- Delete: `Sources/DockTape/Views/ContentView.swift`
- Modify: `Sources/DockTape/Views/RecordingListPane.swift`
- Modify: `Sources/DockTape/Views/DetailPane.swift`
- Modify: `Sources/DockTape/Views/SidebarView.swift`
- Modify: `Sources/DockTape/Views/MultiSelectSummary.swift`

- [ ] **Step 1: Delete ContentView.swift**

```bash
rm Sources/DockTape/Views/ContentView.swift
```

The NavigationSplitView layout is now handled by MainSplitViewController. The sheet/alert logic from ContentView (device info sheet, error alert) moves into the individual pane views — the device info sheet moves to SidebarView, the error alert moves to DetailPane.

- [ ] **Step 2: Move device info sheet to SidebarView**

In `SidebarView.swift`, add the sheet modifier after the existing `.alert("New Folder"...)` block:

```swift
.sheet(isPresented: $state.device.showDeviceInfo) {
    NavigationStack {
        DeviceInfoView(state: state)
    }
}
```

- [ ] **Step 3: Move error alert to DetailPane**

In `DetailPane.swift`, add the error alert to the outer `VStack` body:

```swift
.alert("Error", isPresented: Binding(
    get: { state.errorMessage != nil },
    set: { if !$0 { state.errorMessage = nil } }
)) {
    Button("Dismiss", role: .cancel) { state.errorMessage = nil }
} message: {
    Text(state.errorMessage ?? "")
}
```

- [ ] **Step 4: Strip safeAreaInset toolbars from RecordingListPane**

Remove the two `.safeAreaInset(edge: .top, spacing: 0)` modifiers and their toolbar views:
- Line 64: remove `.safeAreaInset(edge: .top, spacing: 0) { recordingListToolbar }`
- Line 144: remove `.safeAreaInset(edge: .top, spacing: 0) { deviceListToolbar }`

Also remove the toolbar view properties:
- `recordingListToolbar` (lines 284-299)
- `deviceListToolbar` (lines 301-332)

Keep `sortFilterMenu` (lines 334-387) — it moves into the new in-view header.

- [ ] **Step 5: Add in-view header to RecordingListPane**

Replace the removed safeAreaInset with an in-view header inside the list. Add this as a `Section` header or a view above the list in `recordingsContent`:

```swift
private var recordingsContent: some View {
    VStack(spacing: 0) {
        // In-view header: folder name + count + sort + filter
        listHeader
        
        List(selection: $state.library.selectedRecordings) {
            // ... existing list content
        }
        // ... existing modifiers, but remove safeAreaInset
    }
}

private var listHeader: some View {
    VStack(spacing: 0) {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(recordingTitle)
                    .font(.headline)
                Text("\(filteredRecordings.count) recordings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            sortFilterMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        Divider()
    }
}
```

Apply the same pattern to `deviceContent` — add a header with the device name and count.

- [ ] **Step 6: Replace local searchText with shared state**

In `RecordingListPane.swift`, remove `@State private var searchText = ""` and replace all uses with `state.library.searchText`. Update the `.searchable` binding:

```swift
.searchable(text: $state.library.searchText, prompt: "Search recordings")
```

And in `filteredRecordings` / `filteredDeviceFiles`, replace `searchText` with `state.library.searchText`.

- [ ] **Step 7: Strip inline toolbar from DetailPane**

Remove the detail toolbar block (lines 98-162 in `singleRecordingDetail`):

```swift
// Remove this entire VStack:
VStack(spacing: 0) {
    HStack(spacing: 12) {
        toolbarButton(...)  // Play
        toolbarButton(...)  // Transcribe
        Menu { ... }        // Summarize
        Spacer()
        toolbarButton(...)  // Rename
        toolbarButton(...)  // Reveal
    }
    .padding(...)
    .background(.bar)
    Divider()
}
```

The header (title + date) and tab picker remain.

- [ ] **Step 8: Remove action buttons from MultiSelectSummary**

In `MultiSelectSummary.swift`, remove the `onTranscribe` and `onDelete` callbacks and the action buttons HStack (lines 56-72). Keep only the stats display (count, total size, total duration, transcription status). These actions are now in the NSToolbar.

```swift
struct MultiSelectSummary: View {
    let recordings: [RecordingMetadata]
    let transcriptionStatuses: [String: TranscriptStatus]
    let summaryStatuses: Set<String> // hasSummary set

    // Remove: var onTranscribe / var onDelete
    // Remove: HStack with Transcribe/Delete buttons
    // Keep: Icon, count, stats grid
}
```

Update the call site in `DetailPane.recordingDetail` to remove the callback parameters.

- [ ] **Step 9: Wire up triggerCustomPrompt in DetailPane**

In `DetailPane.swift`'s `singleRecordingDetail`, add an `onChange` observer for `state.triggerCustomPrompt` (same pattern as `triggerRename`):

```swift
.onChange(of: state.triggerCustomPrompt) { _, trigger in
    if trigger, let rec = state.library.recordings.first(where: { $0.filename == state.library.selectedRecording }) {
        customPromptRecording = rec
        customPromptText = ""
        showCustomPromptSheet = true
        state.triggerCustomPrompt = false
    }
}
```

- [ ] **Step 10: Update SidebarView — folder.badge.plus**

In `SidebarView.swift` line 147, change:

```swift
// Before
Image(systemName: "plus")

// After
Image(systemName: "folder.badge.plus")
```

- [ ] **Step 11: Remove didBecomeActive observer from SidebarView**

Remove line 134-136 from SidebarView.swift:

```swift
// Remove this — now handled in AppDelegate.applicationDidBecomeActive
.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
    Task { await state.refreshAll() }
}
```

- [ ] **Step 12: Build to verify**

```bash
cd /Users/anand/Library/CloudStorage/Dropbox/src/vibe/docktape && swift build 2>&1 | tail -30
```

Fix any remaining compile errors from the view changes.

---

## Task 6: NSMenu — Replace SwiftUI Commands

**Files:**
- Create: `Sources/DockTape/AppKit/MainMenu.swift`
- Modify: `Sources/DockTape/DockTapeApp.swift` (delete remaining code)

- [ ] **Step 1: Write MainMenu.swift**

```swift
// Sources/DockTape/AppKit/MainMenu.swift
import AppKit
import HiDockKit

/// Builds the application's main menu bar, replacing SwiftUI Commands.
enum MainMenu {
    static func build(appState: AppState) -> NSMenu {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About DockTape", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let prefsItem = NSMenuItem(title: "Settings...", action: #selector(MainMenuActions.showSettings(_:)), keyEquivalent: ",")
        prefsItem.target = nil // responder chain
        appMenu.addItem(prefsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide DockTape", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit DockTape", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenu = NSMenu(title: "File")
        addItem(fileMenu, "Transcribe", action: #selector(MainMenuActions.transcribe(_:)), key: "t", modifiers: [.command, .shift])
        // Summarize submenu
        let summarizeMenu = NSMenu(title: "Summarize")
        for template in TemplateStore.builtInDefaults {
            let item = NSMenuItem(title: template.name, action: #selector(MainMenuActions.summarizeTemplate(_:)), keyEquivalent: "")
            item.representedObject = template
            summarizeMenu.addItem(item)
        }
        let summarizeItem = NSMenuItem(title: "Summarize", action: nil, keyEquivalent: "")
        summarizeItem.submenu = summarizeMenu
        fileMenu.addItem(summarizeItem)

        fileMenu.addItem(.separator())
        addItem(fileMenu, "Import from Device", action: #selector(MainMenuActions.importFromDevice(_:)), key: "i", modifiers: [.command, .shift])
        fileMenu.addItem(.separator())
        addItem(fileMenu, "Rename...", action: #selector(MainMenuActions.rename(_:)), key: "\r", modifiers: [])
        addItem(fileMenu, "Reveal in Finder", action: #selector(MainMenuActions.revealInFinder(_:)), key: "r", modifiers: [.command, .shift])
        fileMenu.addItem(.separator())
        let deleteItem = NSMenuItem(title: "Delete", action: #selector(MainMenuActions.deleteRecording(_:)), keyEquivalent: "\u{8}") // backspace
        deleteItem.keyEquivalentModifierMask = .command
        fileMenu.addItem(deleteItem)
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: #selector(UndoManager.undo), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: #selector(UndoManager.redo), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        addItem(editMenu, "Find...", action: #selector(MainMenuActions.find(_:)), key: "f", modifiers: .command)
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenu = NSMenu(title: "View")
        addItem(viewMenu, "Show Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), key: "s", modifiers: [.command, .control])
        viewMenu.addItem(.separator())
        addItem(viewMenu, "Show All Recordings", action: #selector(MainMenuActions.showAllRecordings(_:)), key: "1", modifiers: .command)
        addItem(viewMenu, "Show Device", action: #selector(MainMenuActions.showDevice(_:)), key: "2", modifiers: .command)
        viewMenu.addItem(.separator())
        addItem(viewMenu, "Show Previous Tab", action: #selector(MainMenuActions.showPreviousTab(_:)), key: "[", modifiers: [.command, .shift])
        addItem(viewMenu, "Show Next Tab", action: #selector(MainMenuActions.showNextTab(_:)), key: "]", modifiers: [.command, .shift])
        viewMenu.addItem(.separator())
        // Toolbar density
        let densityMenu = NSMenu(title: "Toolbar Style")
        let iconOnly = NSMenuItem(title: "Icon Only", action: #selector(MainMenuActions.toolbarIconOnly(_:)), keyEquivalent: "")
        let textOnly = NSMenuItem(title: "Text Only", action: #selector(MainMenuActions.toolbarTextOnly(_:)), keyEquivalent: "")
        let iconAndText = NSMenuItem(title: "Icon and Text", action: #selector(MainMenuActions.toolbarIconAndText(_:)), keyEquivalent: "")
        densityMenu.addItem(iconOnly)
        densityMenu.addItem(textOnly)
        densityMenu.addItem(iconAndText)
        let densityItem = NSMenuItem(title: "Toolbar Style", action: nil, keyEquivalent: "")
        densityItem.submenu = densityMenu
        viewMenu.addItem(densityItem)
        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Playback menu
        let playbackMenu = NSMenu(title: "Playback")
        addItem(playbackMenu, "Play", action: #selector(MainMenuActions.playPause(_:)), key: "p", modifiers: .command)
        addItem(playbackMenu, "Stop", action: #selector(MainMenuActions.stop(_:)), key: ".", modifiers: .command)
        playbackMenu.addItem(.separator())
        addItem(playbackMenu, "Increase Speed", action: #selector(MainMenuActions.increaseSpeed(_:)), key: "]", modifiers: .command)
        addItem(playbackMenu, "Decrease Speed", action: #selector(MainMenuActions.decreaseSpeed(_:)), key: "[", modifiers: .command)
        addItem(playbackMenu, "Reset Speed", action: #selector(MainMenuActions.resetSpeed(_:)), key: "\\", modifiers: .command)
        let playbackMenuItem = NSMenuItem()
        playbackMenuItem.submenu = playbackMenu
        mainMenu.addItem(playbackMenuItem)

        // Device menu
        let deviceMenu = NSMenu(title: "Device")
        addItem(deviceMenu, "Sync All", action: #selector(MainMenuActions.syncAll(_:)), key: "d", modifiers: [.command, .shift])
        addItem(deviceMenu, "Refresh Device", action: #selector(MainMenuActions.refreshDevice(_:)), key: "", modifiers: [])
        deviceMenu.addItem(.separator())
        addItem(deviceMenu, "Device Info...", action: #selector(MainMenuActions.deviceInfo(_:)), key: "i", modifiers: .command)
        let deviceMenuItem = NSMenuItem()
        deviceMenuItem.submenu = deviceMenu
        mainMenu.addItem(deviceMenuItem)

        // Window menu
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    private static func addItem(_ menu: NSMenu, _ title: String, action: Selector, key: String, modifiers: NSEvent.ModifierFlags) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
    }
}
```

- [ ] **Step 2: Write MainMenuActions responder**

Add to `MainWindowController.swift` (or a new file). This class sits in the responder chain and handles menu actions by forwarding to AppState:

```swift
// Add to MainWindowController.swift — the controller IS the responder for menu actions

// MARK: - Menu Actions (responder chain)

extension MainWindowController {
    @objc func showSettings(_ sender: Any?) {
        // Present settings as a sheet or separate window
        let settingsView = SettingsView(state: appState)
        let hostingController = NSHostingController(rootView: settingsView)
        let settingsWindow = NSWindow(contentViewController: hostingController)
        settingsWindow.title = "Settings"
        settingsWindow.styleMask = [.titled, .closable]
        settingsWindow.setContentSize(NSSize(width: 450, height: 400))
        settingsWindow.center()
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    @objc func transcribe(_ sender: Any?) { transcribeAction(sender) }
    @objc func summarizeTemplate(_ sender: NSMenuItem) { summarizeWithTemplate(sender) }
    @objc func importFromDevice(_ sender: Any?) { importAction(sender) }
    @objc func rename(_ sender: Any?) { appState.triggerRename = true }
    @objc func revealInFinder(_ sender: Any?) {
        guard let rec = selectedLibraryRecordings.first else { return }
        appState.library.revealInFinder(rec)
    }
    @objc func deleteRecording(_ sender: Any?) { deleteAction(sender) }
    @objc func find(_ sender: Any?) { appState.library.isSearchFocused = true }

    @objc func showAllRecordings(_ sender: Any?) { appState.selectedView = .allRecordings }
    @objc func showDevice(_ sender: Any?) {
        guard appState.device.isConnected else { return }
        appState.selectedView = .device
    }
    @objc func showPreviousTab(_ sender: Any?) {
        let tabs = DetailTab.allCases
        if let idx = tabs.firstIndex(of: appState.selectedDetailTab), idx > 0 {
            appState.selectedDetailTab = tabs[idx - 1]
        }
    }
    @objc func showNextTab(_ sender: Any?) {
        let tabs = DetailTab.allCases
        if let idx = tabs.firstIndex(of: appState.selectedDetailTab), idx < tabs.count - 1 {
            appState.selectedDetailTab = tabs[idx + 1]
        }
    }

    @objc func toolbarIconOnly(_ sender: Any?) { window?.toolbar?.displayMode = .iconOnly }
    @objc func toolbarTextOnly(_ sender: Any?) { window?.toolbar?.displayMode = .labelOnly }
    @objc func toolbarIconAndText(_ sender: Any?) { window?.toolbar?.displayMode = .iconAndLabel }

    @objc func playPauseMenu(_ sender: Any?) { playPause(sender) }
    @objc func stop(_ sender: Any?) { appState.playback.stop() }
    @objc func increaseSpeed(_ sender: Any?) {
        let speeds = PlaybackState.speeds
        if let idx = speeds.firstIndex(of: appState.playback.rate), idx + 1 < speeds.count {
            appState.playback.setRate(speeds[idx + 1])
        }
    }
    @objc func decreaseSpeed(_ sender: Any?) {
        let speeds = PlaybackState.speeds
        if let idx = speeds.firstIndex(of: appState.playback.rate), idx > 0 {
            appState.playback.setRate(speeds[idx - 1])
        }
    }
    @objc func resetSpeed(_ sender: Any?) { appState.playback.setRate(1.0) }

    @objc func syncAll(_ sender: Any?) { Task { await appState.syncAll() } }
    @objc func refreshDevice(_ sender: Any?) { Task { await appState.device.refreshDevice() } }
    @objc func deviceInfo(_ sender: Any?) { appState.device.showDeviceInfo = true }
}

// Typealias so MainMenu.swift can reference action selectors without importing MainWindowController
@objc protocol MainMenuActions {
    @objc func showSettings(_ sender: Any?)
    @objc func transcribe(_ sender: Any?)
    @objc func summarizeTemplate(_ sender: NSMenuItem)
    @objc func importFromDevice(_ sender: Any?)
    @objc func rename(_ sender: Any?)
    @objc func revealInFinder(_ sender: Any?)
    @objc func deleteRecording(_ sender: Any?)
    @objc func find(_ sender: Any?)
    @objc func showAllRecordings(_ sender: Any?)
    @objc func showDevice(_ sender: Any?)
    @objc func showPreviousTab(_ sender: Any?)
    @objc func showNextTab(_ sender: Any?)
    @objc func toolbarIconOnly(_ sender: Any?)
    @objc func toolbarTextOnly(_ sender: Any?)
    @objc func toolbarIconAndText(_ sender: Any?)
    @objc func playPause(_ sender: Any?)
    @objc func stop(_ sender: Any?)
    @objc func increaseSpeed(_ sender: Any?)
    @objc func decreaseSpeed(_ sender: Any?)
    @objc func resetSpeed(_ sender: Any?)
    @objc func syncAll(_ sender: Any?)
    @objc func refreshDevice(_ sender: Any?)
    @objc func deviceInfo(_ sender: Any?)
}
```

- [ ] **Step 3: Delete DockTapeApp.swift entirely**

```bash
rm Sources/DockTape/DockTapeApp.swift
```

The AppDelegate, AppCommands, and AppStateFocusedKey are all replaced. Any references to `AppStateFocusedKey` or `FocusedValues.appState` in other files should be removed (there shouldn't be any outside of DockTapeApp.swift and ContentView.swift, which is already deleted).

- [ ] **Step 4: Build to verify**

```bash
cd /Users/anand/Library/CloudStorage/Dropbox/src/vibe/docktape && swift build 2>&1 | tail -30
```

Fix remaining compile errors. Common issues: `DetailPane.DetailTab` → `DetailTab` references, missing `MainMenuActions` protocol conformance.

---

## Task 7: StatusBarController — Replace MenuBarExtra

**Files:**
- Create: `Sources/DockTape/AppKit/StatusBarController.swift`

- [ ] **Step 1: Write StatusBarController.swift**

```swift
// Sources/DockTape/AppKit/StatusBarController.swift
import AppKit
import SwiftUI
import HiDockKit

final class StatusBarController {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var eventMonitor: Any?

    init(appState: AppState) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cable.connector.horizontal", accessibilityDescription: "DockTape")

        popover = NSPopover()
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
```

- [ ] **Step 2: Build to verify**

```bash
cd /Users/anand/Library/CloudStorage/Dropbox/src/vibe/docktape && swift build 2>&1 | tail -20
```

---

## Task 8: Accessibility + Final Polish

**Files:**
- Modify: `Sources/DockTape/AppKit/MainWindowController.swift`

- [ ] **Step 1: Verify all toolbar items have accessibility labels**

Review each toolbar item in `MainWindowController.toolbar(_:itemForItemIdentifier:...)`. Every item must have:
- An `accessibilityDescription` on its image
- A meaningful `label`
- A `toolTip`

These are already set in Task 3's code. Verify none are missing.

- [ ] **Step 2: Add menu item validation**

In `MainWindowController`, implement `NSMenuItemValidation` to enable/disable menu items based on state:

```swift
extension MainWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let hasLibrarySelection = !appState.library.selectedRecordings.isEmpty
        let hasSingleLibrarySelection = appState.library.selectedRecordings.count == 1
        let hasDeviceSelection = !appState.device.selectedDeviceFiles.isEmpty
        let isPlaying = appState.playback.playingFile != nil

        switch menuItem.action {
        case #selector(MainMenuActions.transcribe(_:)):
            return hasLibrarySelection
        case #selector(MainMenuActions.summarizeTemplate(_:)):
            return hasLibrarySelection
        case #selector(MainMenuActions.importFromDevice(_:)):
            return hasDeviceSelection
        case #selector(MainMenuActions.rename(_:)):
            return hasSingleLibrarySelection
        case #selector(MainMenuActions.revealInFinder(_:)):
            return hasLibrarySelection
        case #selector(MainMenuActions.deleteRecording(_:)):
            return hasLibrarySelection || hasDeviceSelection
        case #selector(MainMenuActions.playPause(_:)):
            menuItem.title = appState.playback.isPlaying ? "Pause" : "Play"
            return isPlaying || hasSingleLibrarySelection
        case #selector(MainMenuActions.stop(_:)),
             #selector(MainMenuActions.increaseSpeed(_:)),
             #selector(MainMenuActions.decreaseSpeed(_:)),
             #selector(MainMenuActions.resetSpeed(_:)):
            return isPlaying
        case #selector(MainMenuActions.showDevice(_:)):
            return appState.device.isConnected
        case #selector(MainMenuActions.showPreviousTab(_:)):
            let tabs = DetailTab.allCases
            return tabs.firstIndex(of: appState.selectedDetailTab).map { $0 > 0 } ?? false
        case #selector(MainMenuActions.showNextTab(_:)):
            let tabs = DetailTab.allCases
            return tabs.firstIndex(of: appState.selectedDetailTab).map { $0 < tabs.count - 1 } ?? false
        case #selector(MainMenuActions.syncAll(_:)):
            return appState.device.isConnected && !appState.device.isSyncing
        case #selector(MainMenuActions.refreshDevice(_:)),
             #selector(MainMenuActions.deviceInfo(_:)):
            return appState.device.isConnected
        default:
            return true
        }
    }
}
```

- [ ] **Step 3: Build and run the full app**

```bash
cd /Users/anand/Library/CloudStorage/Dropbox/src/vibe/docktape && xcodegen generate && xcodebuild -project DockTape.xcodeproj -scheme DockTape -configuration Debug -derivedDataPath .build/xcode build 2>&1 | tail -30
```

If Dropbox extended attributes cause codesign issues:

```bash
xattr -cr .build/xcode/Build/Products/Debug/DockTape.app
```

Then rebuild.

- [ ] **Step 4: Manual verification checklist**

Verify:
- [ ] Window opens with Notes-style layout (full-height sidebar, toolbar over detail only)
- [ ] Sidebar toggle button works (Cmd+Ctrl+S)
- [ ] Tracking separator aligns with the split view divider
- [ ] Toolbar items show/hide based on library vs. device context
- [ ] Toolbar items enable/disable based on selection
- [ ] All keyboard shortcuts work (compare against HANDOFF.md table)
- [ ] Settings window opens with Cmd+,
- [ ] Status bar icon shows in menu bar, popover opens on click
- [ ] Multi-selection summary card appears in detail pane
- [ ] Sort/filter in content list header works
- [ ] Toolbar density toggle works (View > Toolbar Style)
- [ ] VoiceOver reads toolbar items correctly

- [ ] **Step 5: Commit — Foundation**

```bash
git add -A
git commit -m "feat: AppKit window host migration — NSSplitViewController + NSToolbar

Replace SwiftUI NavigationSplitView with AppKit shell matching Apple Notes layout:
- Full-height sidebar with traffic lights
- NSToolbar with NSTrackingSeparatorToolbarItem over detail pane only
- Context-sensitive toolbar (library vs device)
- NSMenu replacing SwiftUI Commands with all keyboard shortcuts
- Settings window via NSHostingController
- NSStatusItem replacing MenuBarExtra
- Toolbar density toggle (View > Toolbar Style)
- Multi-selection summary card (no action buttons — toolbar handles actions)
- Accessibility labels on all toolbar items

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Playback Progress — App Nap Fix + Observer

**Files:**
- Modify: `Sources/DockTape/State/PlaybackState.swift`

- [ ] **Step 1: Add App Nap prevention + periodic time observer**

Rewrite `PlaybackState.swift`:

```swift
import SwiftUI
import AVFoundation

/// Audio playback with progress tracking, speed control, and App Nap prevention.
@Observable
@MainActor
final class PlaybackState {
    var playingFile: String?
    var isPlaying: Bool = false
    var rate: Float = 1.0
    var progress: Double = 0
    var duration: Double = 0
    var activeSegmentIndex: Int?

    private var avPlayer: AVPlayer?
    private var endOfPlaybackObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var appNapActivity: NSObjectProtocol?

    /// Transcript segments for active-segment lookup. Set by the view layer.
    var segmentTimestamps: [(start: Double, end: Double)] = []

    static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

    func play(file: String, url: URL) {
        if playingFile == file, avPlayer != nil {
            togglePlayPause()
            return
        }

        stop()

        let playerItem = AVPlayerItem(url: url)
        playerItem.preferredForwardBufferDuration = 2
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = false

        avPlayer = player
        playingFile = file
        isPlaying = true

        // Get duration
        if let asset = playerItem.asset as? AVURLAsset {
            Task {
                let d = try? await asset.load(.duration)
                if let d { self.duration = d.seconds }
            }
        }

        // Prevent App Nap during playback
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            .userInitiatedAllowingIdleSystemSleep,
            reason: "Audio playback in progress"
        )

        // Periodic time observer — 4 updates/second
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.progress = time.seconds
                self.updateActiveSegment()
            }
        }

        // End-of-playback
        endOfPlaybackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stop()
            }
        }

        player.rate = rate
    }

    func togglePlayPause() {
        guard let player = avPlayer else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.rate = rate
            isPlaying = true
        }
    }

    func stop() {
        if let obs = endOfPlaybackObserver {
            NotificationCenter.default.removeObserver(obs)
            endOfPlaybackObserver = nil
        }
        if let obs = timeObserver {
            avPlayer?.removeTimeObserver(obs)
            timeObserver = nil
        }
        if let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
        }
        avPlayer?.pause()
        avPlayer = nil
        playingFile = nil
        isPlaying = false
        progress = 0
        duration = 0
        activeSegmentIndex = nil
        segmentTimestamps = []
    }

    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        avPlayer?.seek(to: cmTime)
        progress = time
        updateActiveSegment()
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        if let player = avPlayer, isPlaying {
            player.rate = newRate
        }
    }

    // MARK: - Active Segment

    private func updateActiveSegment() {
        guard !segmentTimestamps.isEmpty else {
            activeSegmentIndex = nil
            return
        }
        let t = progress
        // Binary search would be overkill for typical segment counts (<500)
        activeSegmentIndex = segmentTimestamps.lastIndex { t >= $0.start && t < $0.end }
            ?? segmentTimestamps.lastIndex { t >= $0.start }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
cd /Users/anand/Library/CloudStorage/Dropbox/src/vibe/docktape && swift build 2>&1 | tail -20
```

---

## Task 10: Scrubber UI in Now Playing Bar

**Files:**
- Modify: `Sources/DockTape/Views/DetailPane.swift` (NowPlayingBar section)

- [ ] **Step 1: Update NowPlayingBar with interactive scrubber**

Replace the `NowPlayingBar` struct in `DetailPane.swift`:

```swift
struct NowPlayingBar: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 6) {
                // Title row
                HStack(spacing: 12) {
                    Button {
                        state.playback.togglePlayPause()
                    } label: {
                        Image(systemName: state.playback.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 20)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(state.playback.isPlaying ? "Pause" : "Play")

                    if let file = state.playback.playingFile {
                        let rec = state.library.recordings.first { $0.filename == file }
                        Text(rec?.displayTitle ?? file)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    }

                    Spacer()

                    // Time display
                    Text("\(formatTime(state.playback.progress)) / \(formatTime(state.playback.duration))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Menu {
                        ForEach(PlaybackState.speeds, id: \.self) { speed in
                            Button {
                                state.playback.setRate(speed)
                            } label: {
                                HStack {
                                    Text(speedLabel(speed))
                                    if state.playback.rate == speed { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        Text(speedLabel(state.playback.rate))
                            .font(.caption.monospacedDigit().weight(.medium))
                            .frame(minWidth: 30)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Playback speed")

                    Button {
                        state.playback.stop()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Stop playback")
                }

                // Scrubber
                if state.playback.duration > 0 {
                    Slider(
                        value: Binding(
                            get: { state.playback.progress },
                            set: { state.playback.seek(to: $0) }
                        ),
                        in: 0...state.playback.duration
                    )
                    .controlSize(.mini)
                    .accessibilityLabel("Playback position")
                    .accessibilityValue(formatTime(state.playback.progress))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func speedLabel(_ rate: Float) -> String {
        if rate == 1.0 { return "1×" }
        if rate == floor(rate) { return "\(Int(rate))×" }
        return String(format: "%.2g×", rate)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
cd /Users/anand/Library/CloudStorage/Dropbox/src/vibe/docktape && swift build 2>&1 | tail -20
```

---

## Task 11: Transcript Highlighting + Auto-Scroll

**Files:**
- Modify: `Sources/DockTape/Views/TranscriptViewer.swift`
- Modify: `Sources/DockTape/Views/DetailPane.swift` (wire up segmentTimestamps)

- [ ] **Step 1: Set segmentTimestamps when transcript loads**

In `DetailPane.swift`, in the `singleRecordingDetail` method, find the `.task(id: rec.filename)` block and add after the transcript load:

```swift
.task(id: rec.filename) {
    transcript = await state.library.transcript(for: rec.filename)
    userTemplates = await state.templateStore.userCreatedTemplates()

    // Set segment timestamps for playback highlighting
    if let t = transcript {
        state.playback.segmentTimestamps = t.segments.map { (start: $0.start, end: $0.end) }
    } else {
        state.playback.segmentTimestamps = []
    }

    if !userHasPickedTab {
        state.selectedDetailTab = transcript != nil ? .transcript : .info
    } else {
        ensureTabAvailable(for: rec)
    }
}
```

- [ ] **Step 2: Add highlight styling to TranscriptViewer**

In `TranscriptViewer.swift`, the segment list is rendered around line 88-121 in a `ScrollViewReader` > `LazyVStack` > `ForEach`. The `ForEach` iterates over `displaySegments` using `segment.id`. Change the loop to use `Array(displaySegments.enumerated())` so we have the index. Then add a highlight background to each `SegmentRow`:

```swift
// Before:
ForEach(displaySegments) { segment in
    SegmentRow(...)
}

// After:
ForEach(Array(displaySegments.enumerated()), id: \.element.id) { index, segment in
    SegmentRow(...)
        .background(
            activeSegmentIndex == index
                ? Color.accentColor.opacity(0.12)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .id(index)
}
```

The `displaySegments` are the filtered segments (possibly filtered by speaker). The `index` here corresponds to the filtered index, which matches `activeSegmentIndex` since `updateActiveSegment()` in PlaybackState uses the same segment list via `segmentTimestamps`. If speaker filtering is active, the timestamps array should also be filtered — add this to the `segmentTimestamps` setter in Task 11 Step 1 by filtering to match `displaySegments`.

- [ ] **Step 3: Add auto-scroll**

In the `ScrollViewReader` that wraps the segment list, add an `onChange` for `activeSegmentIndex`:

```swift
ScrollViewReader { proxy in
    LazyVStack(alignment: .leading, spacing: 8) {
        // ... segments
    }
    .onChange(of: activeSegmentIndex) { _, newIndex in
        if let idx = newIndex {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(idx, anchor: .center)
            }
        }
    }
}
```

- [ ] **Step 4: Build and test**

```bash
cd /Users/anand/Library/CloudStorage/Dropbox/src/vibe/docktape && swift build 2>&1 | tail -20
```

- [ ] **Step 5: Manual verification**

- [ ] Play a recording — Now Playing bar shows at bottom with scrubber
- [ ] Scrubber updates in real-time (not throttled by App Nap)
- [ ] Click/drag scrubber to seek
- [ ] Switch to Transcript tab — active segment highlights
- [ ] Transcript auto-scrolls to keep active segment visible
- [ ] Stop playback — highlight clears, Now Playing bar hides

- [ ] **Step 6: Commit — Playback**

```bash
git add -A
git commit -m "feat: playback progress tracking + transcript highlighting

Enable real-time playback features on the AppKit window host:
- App Nap prevention via ProcessInfo.beginActivity during playback
- Periodic time observer (4 updates/sec) drives progress + duration
- Interactive scrubber in Now Playing bar (click/drag to seek)
- Active transcript segment highlighting with auto-scroll
- Speed badge in Now Playing bar

This commit can be reverted independently — the AppKit shell from
the previous commit stands on its own.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Update Documentation

**Files:**
- Modify: `docs/DEVELOPMENT.md`

- [ ] **Step 1: Update DEVELOPMENT.md**

Update the status line, architecture section, and key design decisions to reflect the AppKit migration:
- Stack: add "AppKit (NSSplitViewController, NSToolbar)"
- Status: "AppKit window host migration complete. Playback progress and transcript highlighting active."
- Architecture: update Three-pane layout description
- Key Design Decision #6: replace the safeAreaInset workaround note with the AppKit approach
- Key Design Decision #9: update playback progress status
- Remove the `activeSegmentIndex` cleanup TODO from gotchas

- [ ] **Step 2: Commit docs**

```bash
git add docs/DEVELOPMENT.md
git commit -m "docs: update DEVELOPMENT.md for AppKit migration

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```
