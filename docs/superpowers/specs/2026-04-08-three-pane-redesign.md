# DockTape 3-Pane Redesign

**Date:** 2026-04-08
**Status:** Draft — pending review

## Summary

Redesign DockTape from a 2-column layout (sidebar + detail) to a 3-pane layout modeled on Mail.app, with real filesystem folders in the sidebar, a recording list middle pane, and a progressive tabbed detail pane. Simultaneously refactor the monolithic `AppState` into focused sub-objects to eliminate cascade re-renders from the 4Hz playback timer.

## Design Principles

1. **Portability** — all data lives in files and directory structure that humans and other tools can read directly. No separate metadata database for organization.
2. **Progressive disclosure** — UI elements (tabs, toolbar actions) appear only when relevant content exists.
3. **macOS HIG compliance** — actions in toolbar + menu bar, not inline CTAs. Standard `NavigationSplitView` three-column layout. Every toolbar action has a menu bar equivalent with a keyboard shortcut.
4. **Filesystem as source of truth** — folders are real directories. The app watches and reflects the filesystem, never caches a separate folder model.

### Metadata Portability (Open Question)

Transcripts are currently stored as sidecar JSON files (`recording.json` alongside `recording.mp3`). This works but creates an orphaning risk when files are moved outside the app. As more per-recording artifacts are added (summaries, action items), this tension grows. Possible future directions:
- **Sidecar convention** (current) — predictable naming, easy to inspect, risk of orphaning on external move
- **Embed in MP3 ID3 tags** — single file, truly portable, harder to inspect
- **Directory-per-recording** — each recording is a folder containing all its artifacts, most extensible

For this redesign: continue with sidecar convention. All move/rename/delete operations must always move the full set of associated files (MP3 + transcript JSON + any future sidecars) as a unit. This is a prerequisite for folder drag-and-drop.

## Architecture

### 1. Three-Pane Layout

Convert `ContentView` from `NavigationSplitView { sidebar } detail: { ... }` to the three-column variant:

```swift
NavigationSplitView {
    Sidebar(library: state.library, device: state.device)
} content: {
    RecordingListPane(library: state.library, device: state.device)
} detail: {
    DetailPane(
        library: state.library,
        device: state.device,
        playback: state.playback,
        transcription: state.transcription
    )
}
```

Minimum window size increases from 800×500 to 900×550 to accommodate the third column.

### 2. Sidebar (Column 1)

Two sections:

**Library section:**
- "All Recordings" — always present, shows all recordings across all folders
- User-created folders — one level deep, reflecting top-level directories under the Library path on disk
- Selecting a folder filters the middle pane to recordings within that folder (recursively, including subfolders)
- Folder count badge on each item

**Device section:**
- Shows actual device name (e.g., "HiDock P1") — never a generic "On Device" label. Uses `device.model.rawValue`.
- Green dot indicator when connected
- Device status footer: connection state, battery, storage (same as current sidebar footer)

**Folder management:**
- "+" button at bottom of Library section to create a new folder
- Right-click context menu: New Folder, Rename, Delete
- Drag-and-drop: recordings from the middle pane can be dropped onto sidebar folders to move them
- Filesystem-watched: changes made in Finder are reflected immediately (use `DispatchSource.makeFileSystemObjectSource` or poll on `NSApplication.didBecomeActiveNotification`)

**No pre-created folders.** First launch shows only "All Recordings". A first-run hint or empty state message guides the user to create folders via the "+" button.

**Subfolders:** Supported on disk, but not shown as nested items in the sidebar. Selecting a parent folder shows all recordings within it recursively. Users who want subfolder organization can create them in Finder.

### 3. Recording List (Column 2)

The middle pane shows a list of recordings filtered by the sidebar selection:

- **"All Recordings" selected** → all library recordings
- **A folder selected** → recordings in that folder (recursively)
- **"On Device" selected** → device file list (same as current `DeviceFilesView`)

Header shows the current context name and item count. Search bar filters the current list.

Sort and filter controls remain in the toolbar (not the sidebar). Sort options simplified to two pairs: **Newest/Oldest** (by date) and **Longest/Shortest** (by actual MP3 duration from file metadata, not estimated from size). The previous Largest/Smallest sort is removed — file size is visible in the Info tab but not a useful sort axis since duration is what users care about and the two produced identical orderings with fixed-bitrate HiDock audio. Type filter (Recording, Phone, Meeting, WIP) and date filter remain in toolbar filter menu.

Selection: single or multi-select. Selection drives the detail pane content.

**Multi-select behavior:** When multiple items are selected, the detail pane shows a summary card (similar to Mail's stacked message view): item count, total duration, total size, and a list of titles. Toolbar actions:
- **Delete, Export, Download, Move** — apply to all selected items
- **Transcribe** — queues all selected items for sequential transcription
- **Play** — disabled (no meaningful single-item action)

**Empty state:** When no recording is selected (e.g., empty folder), the detail pane shows `ContentUnavailableView` with contextual message ("Select a recording" or "No recordings in this folder").

### 4. Detail Pane (Column 3)

Content adapts based on what's selected and what data is available.

**Progressive tabs:**
- Tab bar is only rendered when there are 2+ tabs
- Tabs are computed from available data for the selected recording:

| Data available | Tabs shown | Tab bar visible? |
|---|---|---|
| Device file (not downloaded) | Info only | No |
| Library recording, no transcript | Info only | No |
| Library recording, has transcript | Transcript, Info | Yes (Transcript default) |
| Future: has summary | Transcript, Summary, Info | Yes |
| Future: has action items | Transcript, Summary, Actions, Info | Yes |

Implementation: a computed `availableTabs` array. Tab bar renders only when `availableTabs.count > 1`.

**Info tab contents:**
- Filename, duration, size, mode, date, folder
- For device files: status ("On device"), estimated duration
- For library recordings: download date, transcript status

**Transcript tab contents:**
- Speaker-labeled segments with timestamps, search, copy, export

**Live highlight + click-to-seek:**
- During playback, the currently-playing segment is highlighted (subtle background color or leading accent bar) and auto-scrolled into view
- Active segment is computed by comparing `PlaybackState.progress` against segment start timestamps — derived as `activeSegmentIndex`, which changes infrequently (~every 10-15s) even though progress updates at 4Hz
- Clicking any transcript segment seeks playback to that segment's start timestamp (bidirectional: player → transcript highlight, transcript click → player seek)
- If playback is stopped, clicking a segment starts playback from that point

**Speaker management:**
- **Rename speaker** — existing feature, carried forward
- **Split speaker** — right-click a segment → "Assign Different Speaker" → creates a new speaker ID for that segment (and optionally all following segments by that speaker). Handles cases where diarization conflates two people into one speaker ID.
- **Merge speakers** — right-click a speaker label → "Merge with..." → submenu of other speakers. Rewrites all segments from the selected speaker to the target speaker ID.
- All speaker edits persist to the transcript JSON sidecar immediately.
- *Speaker split/merge is cuttable from this release if scope requires — the UI scaffolding (context menus on segments) ships regardless.*

**Player bar:**
- Pinned at the bottom of the detail pane (not the window)
- Visible when a library recording is selected (not for device files — can't play until downloaded)
- Play/pause, seek slider, time display, speed picker, stop button
- Same as current `NowPlayingBar` but scoped to the detail pane

**Transcription progress bar:**
- Appears above the player bar when transcription is active
- Same as current `TranscriptionBar`

### 5. Toolbar

Contextual — buttons change based on sidebar selection and item state.

**Library recording selected:**
| Button | Icon | Shortcut | Condition |
|---|---|---|---|
| Play/Pause | `play.fill` / `pause.fill` | ⌘P | Always |
| Transcribe | `text.word.spacing` | ⌘T | Always (re-transcribe if exists) |
| Export | `square.and.arrow.up` | ⌘E | Always |
| Delete | `trash` | ⌘⌫ | Always |

**Device file selected:**
| Button | Icon | Shortcut | Condition |
|---|---|---|---|
| Download | `arrow.down.circle` | ⌘D | Not already downloaded |
| Delete from Device | `trash` | ⌘⌫ | Always |
| Refresh | `arrow.clockwise` | ⌘R | Always |

**Sort & filter** remain as trailing toolbar items (same as current).

### 6. Menu Bar

```
File
├── New Folder                    ⌘N
├── ─────────
├── Download from Device          ⌘D      (disabled when no device file selected)
├── Export...                     ⌘E
├── ─────────
├── Delete                        ⌘⌫
├── ─────────
├── Close Window                  ⌘W

Edit
├── Find                          ⌘F

View
├── Show Library                  ⌘1
├── Show Device                   ⌘2
├── ─────────
├── Toggle Sidebar                ⌘⌥S
├── Get Info                      ⌘I      (device info)

Recording
├── Play / Pause                  ⌘P
├── Stop                          ⌘.
├── ─────────
├── Transcribe                    ⌘T
├── ─────────
├── Increase Speed                ⌘]
├── Decrease Speed                ⌘[
├── Reset Speed                   ⌘\
├── ─────────
├── Move to →                     (submenu of folders)

Device
├── Refresh Files                 ⌘R
├── Sync All                      ⌘⇧S
├── Device Info                   ⌘⇧I
```

### 7. AppState Refactor

Split the monolithic `AppState` (~30 properties) into four focused `@Observable @MainActor` sub-objects:

```
AppState (coordinator)
├── library: LibraryState
├── device: DeviceState
├── playback: PlaybackState
└── transcription: TranscriptionState
```

**LibraryState:**
- `recordings: [RecordingMetadata]`
- `folders: [String]` — top-level folder names, read from disk
- `selectedFolder: String?` — nil means "All Recordings"
- `selectedRecording: String?`
- `downloadedFilenames: Set<String>` — O(1) lookup cache
- Methods: `loadRecordings()`, `createFolder(_:)`, `renameFolder(_:to:)`, `deleteFolder(_:)`, `moveRecording(_:toFolder:)`, `deleteRecording(_:)`

**DeviceState:**
- `model: DeviceModel?`
- `isConnected: Bool`
- `files: [FileEntry]`
- `downloadingFiles: Set<String>`
- `deletingFiles: Set<String>`
- `selectedDeviceFile: String?`
- Methods: `refreshDevice()`, `downloadFile(_:)`, `deleteFromDevice(_:)`, `syncAll()`

**PlaybackState:**
- `playingFile: String?`
- `isPlaying: Bool`
- `progress: Double` — the 4Hz property, now isolated
- `duration: Double`
- `rate: Float`
- Methods: `play(_:)`, `togglePlayPause()`, `stop()`, `seek(to:)`, `setRate(_:)`

**TranscriptionState:**
- `transcribingFile: String?`
- `phase: String`
- `queue: [String]`
- `queueIndex: Int`
- `startTime: Date?`
- Methods: `transcribe(_:)`, `cancel()`

**Cross-cutting actions** remain on `AppState`:
- `downloadAndTranscribe(file:)` — coordinates DeviceState → LibraryState → TranscriptionState
- `deleteRecording(_:)` — stops playback if active, removes from library
- `setup()` — initializes all sub-objects, starts device monitoring

**Performance impact:** `PlaybackState.progress` updating at 4Hz only invalidates `PlayerBar` — not the sidebar, recording list, or transcript viewer. This is the primary performance win.

**Playback responsiveness fixes** (migrated into `PlaybackState`):
- Replace `Timer.scheduledTimer` polling with `AVPlayer.addPeriodicTimeObserver(forInterval:queue:)` for pipeline-synchronized progress updates
- Replace sample-accurate seeking (`toleranceBefore: .zero, toleranceAfter: .zero`) with default tolerances for interactive scrubbing — eliminates 100-200ms seek latency on compressed audio

### 8. Filesystem Watching

The Library folder is watched for external changes:

- On app activate (`NSApplication.didBecomeActiveNotification`): rescan folder list and recording list
- Optionally, `DispatchSource.makeFileSystemObjectSource` on the Library directory for real-time updates

`LibraryState.folders` is always derived from the filesystem — never cached independently.

### 9. Drag and Drop

- **Recording list → sidebar folder**: moves the recording's file(s) (MP3 + JSON transcript if exists) to the target folder directory on disk, then refreshes the library state
- **Multi-select supported**: drag multiple recordings to a folder
- Standard macOS drag feedback (insertion indicator on sidebar folder)

## Out of Scope

- Subfolder display in sidebar (subfolders work on disk, flattened in UI)
- Pre-created sample folders
- Summary tab / AI features (future: add tab when feature ships)
- Action items / task extraction (future)
- Todo/calendar app integration (future)
- USBDeviceMonitor thread safety refactor (independent, separate PR)
- FluidTranscriber/FluidDiarizer → actor refactor (independent, separate PR)
- Settings view changes
- Menu bar extra (system tray) changes

## File Impact

**New files:**
- `Sources/DockTape/State/LibraryState.swift`
- `Sources/DockTape/State/DeviceState.swift`
- `Sources/DockTape/State/PlaybackState.swift`
- `Sources/DockTape/State/TranscriptionState.swift`
- `Sources/DockTape/Views/Sidebar.swift`
- `Sources/DockTape/Views/RecordingListPane.swift`
- `Sources/DockTape/Views/DetailPane.swift`
- `Sources/DockTape/Views/InfoTab.swift`

**Major changes:**
- `Sources/DockTape/AppState.swift` — gutted to thin coordinator
- `Sources/DockTape/Views/ContentView.swift` — 3-column NavigationSplitView, passes sub-objects
- `Sources/DockTape/DockTapeApp.swift` — new menu bar structure (AppCommands rewrite)

**Minor changes:**
- `Sources/DockTape/Views/TranscriptViewer.swift` — receives `PlaybackState` instead of full `AppState`
- `Sources/DockTape/Views/NowPlayingBar.swift` (extracted from ContentView) — receives `PlaybackState`
- `Sources/DockTape/Views/TranscriptionBar.swift` (extracted from ContentView) — receives `TranscriptionState`

**Removed / replaced:**
- `Sources/DockTape/Views/RecordingListView.swift` — replaced by `RecordingListPane.swift`
- `Sources/DockTape/Views/DeviceFilesView.swift` — functionality merged into `RecordingListPane.swift` (middle pane adapts to sidebar selection)
- `Sources/DockTape/Views/DownloadProgressView.swift` — download progress shown inline in device file list rows (already partially done)
