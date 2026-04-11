# AppKit Window Host Migration — Design Spec

## Goal

Replace the SwiftUI `NavigationSplitView` + `.safeAreaInset` toolbar workaround with a proper AppKit window shell using `NSSplitViewController` + `NSToolbar` + `NSTrackingSeparatorToolbarItem`. Enable playback progress tracking and transcript highlighting by controlling App Nap at the window level. Model the layout after Apple Notes/Mail.

## Architecture

### Window Structure

Full AppKit shell. `@main` moves from `DockTapeApp: App` to an `NSApplicationDelegate` that creates the window programmatically. All SwiftUI views are hosted via `NSHostingController` inside `NSSplitViewItem`s.

```
NSApplication
  └─ AppDelegate (owns AppState, creates main window)
      ├─ MainWindowController : NSWindowController
      │   ├─ NSToolbar (delegate = controller)
      │   │   ├─ NSTrackingSeparatorToolbarItem (tracks divider between list & detail)
      │   │   ├─ play/pause
      │   │   ├─ transcribe
      │   │   ├─ summarize (dropdown)
      │   │   ├─ import
      │   │   ├─ delete
      │   │   ├─ refresh
      │   │   ├─ flexible space
      │   │   └─ search
      │   │
      │   └─ MainSplitViewController : NSSplitViewController
      │       ├─ NSSplitViewItem(.sidebar) → NSHostingController<SidebarView>
      │       │   Full-height, extends into titlebar, traffic lights embedded
      │       ├─ NSSplitViewItem(.contentList) → NSHostingController<RecordingListView>
      │       │   In-view header: folder name, count, sort, filter
      │       └─ NSSplitViewItem(.init) → NSHostingController<DetailPaneView>
      │           Toolbar items appear above this pane only
      │
      ├─ SettingsWindowController (NSHostingController<SettingsView>)
      └─ MenuBarExtra (SwiftUI, unchanged)
```

### Key Architectural Decisions

1. **Full AppKit shell, not hybrid** — NSToolbar must be owned by the window; NSTrackingSeparatorToolbarItem must be tied to the NSSplitViewController. Embedding NSSplitViewController inside a SwiftUI window via NSViewRepresentable requires hacking window access and produces fragile toolbar alignment. Full AppKit shell is how Apple's own apps do it.

2. **Notes-style layout** — Sidebar is full-height into the titlebar (traffic lights sit in the sidebar zone). Toolbar only spans the detail pane, right of the tracking separator. Content list has its own in-view header, not toolbar items.

3. **AppState unchanged** — Still `@Observable @MainActor`, passed to each `NSHostingController`'s root view via `.environment()`. No changes to the state layer or HiDockKit.

4. **SwiftUI views mostly unchanged** — SidebarView, RecordingListView (renamed from RecordingListPane), DetailPaneView move from being children of NavigationSplitView to being hosted in NSHostingControllers. Remove NavigationSplitView, `.safeAreaInset` toolbars, and `.toolbar(.hidden)`. Internal view content stays the same.

## Toolbar Design

### Detail Pane Toolbar (NSToolbar)

All item-action buttons live in the NSToolbar above the detail pane. They are context-sensitive based on sidebar selection (library folder vs. device) and recording selection count.

| Button | SF Symbol | Library | Device | Single | Multi | None |
|--------|-----------|---------|--------|--------|-------|------|
| Play/Pause | play.fill / pause.fill | ✓ | ✗ | ✓ | ✗ | ✗ |
| Transcribe | text.quote | ✓ | ✗ | ✓ | ✓ | ✗ |
| Summarize ▾ | sparkles | ✓ | ✗ | ✓ | ✓ | ✗ |
| Import | square.and.arrow.down | ✗ | ✓ | ✓ | ✓ | ✗ |
| Delete | trash | ✓ | ✓ | ✓ | ✓ | ✗ |
| Refresh | arrow.clockwise | ✓ | ✓ | Always enabled | | |
| Search | magnifyingglass | ✓ | ✓ | Always enabled | | |

Context switching: When the sidebar selection changes between a library folder and the device, the toolbar swaps visible items. Implementation via `toolbar.removeItem(at:)` / `toolbar.insertItem(withItemIdentifier:at:)` or hiding/showing items.

Summarize uses an `NSMenuToolbarItem` (dropdown) for template selection, matching the current dropdown behavior.

All toolbar items must have accessibility labels (per AppKit accessibility requirements — icon-only buttons without labels are a P0 VoiceOver blocker).

### Content List In-View Header

Not part of the NSToolbar. Lives inside RecordingListView as a SwiftUI view.

| Item | Icon | Behavior |
|------|------|----------|
| Folder Name | — | Title + recording count |
| Sort | arrow.up.arrow.down | Dropdown: by date, name, duration |
| Filter | line.3.horizontal.decrease.circle | First-class button — filter by type, size, date, etc. |

No Select All — standard click + shift/cmd-click + scroll selection.

### Sidebar

- `folder.badge.plus` icon for adding folders (replaces generic plus)
- Standard sidebar toggle button in the toolbar (macOS provides this automatically with `NSSplitViewItem(.sidebar)`)

## Multi-Selection

When 2+ recordings are selected, the detail pane shows a summary card (Finder-style):

- Stacked recording icon
- "N Recordings Selected"
- Aggregate info: total duration, total size
- Status counts: "X transcribed, Y summarized, Z not transcribed"
- Toolbar actions apply to all selected recordings

When nothing is selected, the detail pane shows a `ContentUnavailableView`-style empty state.

## Playback

### Now Playing Bar

Pinned to the **bottom** of the detail pane — fixed position, never scrolls, never moves. Visible only when a recording is playing.

Contents:
- Play/pause toggle button
- Recording name
- Time display: current / total
- Interactive scrubber (click/drag to seek)
- Speed badge (shows current rate like "1.5×", click to cycle through presets)

### Progress Tracking (App Nap Fix)

The core problem: macOS App Nap throttles all timer mechanisms when it determines the app is "inactive." Previous attempts with `ProcessInfo.beginActivity()` didn't reliably fix this.

Strategy:
1. **Primary:** `AVPlayer.addPeriodicTimeObserver` with an interval of ~0.25s. AppKit windows with visible, updating content are less aggressively napped than SwiftUI-only windows.
2. **App Nap prevention:** During active playback, call `ProcessInfo.processInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep, reason: "Audio playback")` and hold the activity token until playback stops.
3. **Fallback:** If periodic observer still throttles, upgrade to `CADisplayLink` (macOS 14+) tied to the window's display for frame-rate-accurate updates.

Progress flows: AVPlayer → PlaybackState.progress/duration → SwiftUI binding → scrubber + transcript highlight.

### Transcript Highlighting

When playing and the Transcript tab is active:
- `PlaybackState.activeSegmentIndex` (already exists, currently always nil) is updated by the progress observer based on segment timestamps
- `TranscriptViewer` already accepts `activeSegmentIndex` — wire it up to highlight the current segment
- Auto-scroll to keep the active segment visible

## Menu Bar

SwiftUI `Commands { }` blocks replaced with `NSMenu` built programmatically. Actions route through the responder chain: menu item → `MainWindowController` → `AppState`.

All existing keyboard shortcuts preserved (see HANDOFF.md for the full table). Same menu structure: File, Edit, View, Playback, Device.

## Settings

Existing `SettingsView` (SwiftUI) hosted in a separate `NSWindow` via `NSHostingController`. Opened via Cmd+, (standard menu item). No changes to SettingsView content.

## MenuBarExtra

Kept as SwiftUI. Without `@main App`, the `MenuBarExtra` scene API is unavailable. Instead, create an `NSStatusItem` in `AppDelegate.applicationDidFinishLaunching` with an `NSHostingView` wrapping the existing `MenuBarView`. The status item uses the same `cable.connector.horizontal` system image.

## Accessibility

Per the AppKit Accessibility Auditor skill requirements:

- **Toolbar items:** All must have `setAccessibilityLabel()` — no icon-only buttons without labels
- **Key view loop:** Tab/Shift-Tab must reach all interactive elements across panes
- **Split view dividers:** Keyboard-accessible for resizing
- **Sidebar toggle:** Keyboard-reachable
- **Now Playing bar:** VoiceOver must announce playback state, current time, and recording name
- **Multi-selection card:** VoiceOver must read count and aggregate info
- **Announcements:** Selection changes and playback state changes announced via `NSAccessibility.post(element:notification:)`

## Commit Strategy

Two commits, structured so playback can be backed off independently:

### Commit 1 — AppKit Shell + NSToolbar (ship-safe)

- AppDelegate with NSApplicationDelegate lifecycle
- MainWindowController with NSToolbar + NSTrackingSeparatorToolbarItem
- MainSplitViewController with three NSSplitViewItems
- Three NSHostingControllers hosting existing SwiftUI views
- NSMenu replacing SwiftUI Commands
- SettingsWindowController
- Context-sensitive toolbar (library vs. device)
- Multi-selection summary card in detail pane
- Content list in-view header (folder name, sort, filter)
- `folder.badge.plus` for add folder
- Remove NavigationSplitView, `.safeAreaInset` toolbars, `.toolbar(.hidden)`
- Accessibility labels on all toolbar items

### Commit 2 — Playback Progress + Transcript Highlighting (revertible)

- App Nap prevention during playback
- Progress observer (periodic time observer → PlaybackState.progress)
- Scrubber UI in Now Playing bar (pinned to detail pane bottom)
- `activeSegmentIndex` update from progress observer
- Transcript segment highlighting in TranscriptViewer
- Auto-scroll to active segment
- Remove the `activeSegmentIndex` nil passthrough cleanup TODO

If App Nap still fights us after commit 2, revert to commit 1 — the AppKit shell and toolbar improvements stand on their own.

### Commit 1 also includes

- **Toolbar density toggle** — View menu item to switch `NSToolbar.displayMode` between `.iconOnly`, `.labelOnly`, and `.iconAndLabel`. One line of code plus a menu item.

## Out of Scope

- Transcription model selection (alternative ASR models)
- Drag and drop reordering of toolbar items (NSToolbar supports this natively, comes for free)
