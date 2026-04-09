# DockTape 3-Pane Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert DockTape from a 2-column layout to a 3-pane Mail.app-style layout with real filesystem folders, progressive tabbed detail, AppState decomposition, and playback responsiveness fixes.

**Architecture:** Split monolithic `AppState` into four `@Observable @MainActor` sub-objects (LibraryState, DeviceState, PlaybackState, TranscriptionState). Replace the 2-column `NavigationSplitView` with a 3-column variant. The sidebar shows real filesystem folders + device; the middle pane lists recordings filtered by sidebar selection; the detail pane shows progressive tabs (Info only → Transcript + Info) with a pinned player bar.

**Tech Stack:** Swift 5.10, SwiftUI (macOS 14+), AVFoundation, HiDockKit (local SPM library). Build with `xcodebuild -scheme DockTape`. Tests: `xcodebuild test -scheme HiDockKitTests`.

---

## File Structure

### New files

| File | Responsibility |
|---|---|
| `Sources/DockTape/State/LibraryState.swift` | Recordings, folders, selection, folder CRUD, filesystem scanning |
| `Sources/DockTape/State/DeviceState.swift` | Device model, connection, file list, download/delete ops |
| `Sources/DockTape/State/PlaybackState.swift` | AVPlayer, progress (4Hz), seek, rate — isolated from other views |
| `Sources/DockTape/State/TranscriptionState.swift` | Transcription queue, phase, pipeline lifecycle |
| `Sources/DockTape/Views/SidebarView.swift` | Column 1: Library folders + Device section + status footer |
| `Sources/DockTape/Views/RecordingListPane.swift` | Column 2: Recording/device file list, adapts to sidebar selection |
| `Sources/DockTape/Views/DetailPane.swift` | Column 3: Progressive tabs, coordinates Info/Transcript/PlayerBar |
| `Sources/DockTape/Views/InfoTabView.swift` | Info tab: metadata grid for recordings and device files |
| `Sources/DockTape/Views/MultiSelectSummary.swift` | Multi-select detail: count, duration, titles, batch actions |
| `Tests/HiDockKitTests/RecordingStoreFolderTests.swift` | Tests for folder-aware RecordingStore methods |
| `Tests/HiDockKitTests/TranscriptStoreDebouncedTests.swift` | Tests for coalesced TXT regeneration |

### Modified files

| File | Changes |
|---|---|
| `Sources/DockTape/AppState.swift` | Gutted to thin coordinator holding 4 sub-objects |
| `Sources/DockTape/Views/ContentView.swift` | 3-column NavigationSplitView, passes sub-objects |
| `Sources/DockTape/DockTapeApp.swift` | Full menu bar rewrite (File, View, Recording, Device menus) |
| `Sources/DockTape/Views/TranscriptViewer.swift` | Embedded in detail pane (not sheet), live highlight, speaker split/merge context menus |
| `Sources/HiDockKit/Storage/RecordingStore.swift` | Add folder-aware scanning, moveRecording, recursive enumeration |
| `Sources/HiDockKit/Transcription/TranscriptStore.swift` | Coalesced TXT writes, stale TXT detection on load |

### Removed files

| File | Replaced by |
|---|---|
| `Sources/DockTape/Views/RecordingListView.swift` | `RecordingListPane.swift` |
| `Sources/DockTape/Views/DeviceFilesView.swift` | Merged into `RecordingListPane.swift` |
| `Sources/DockTape/Views/DownloadProgressView.swift` | Inline progress in device file rows |
| `Sources/DockTape/Views/EmptyStateView.swift` | Inline `ContentUnavailableView` in each pane |

---

## Task 1: RecordingStore — Folder-Aware Storage

Add folder support to `RecordingStore` so it can scan subdirectories, move files between folders, and create/delete/rename folders. This is the foundation everything else builds on.

**Files:**
- Modify: `Sources/HiDockKit/Storage/RecordingStore.swift`
- Modify: `Sources/HiDockKit/Storage/RecordingMetadata.swift`
- Create: `Tests/HiDockKitTests/RecordingStoreFolderTests.swift`

- [ ] **Step 1: Write failing tests for folder operations**

```swift
// Tests/HiDockKitTests/RecordingStoreFolderTests.swift
import XCTest
@testable import HiDockKit

final class RecordingStoreFolderTests: XCTestCase {

    var tmpDir: URL!
    var store: RecordingStore!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = RecordingStore(baseDirectory: tmpDir)
        try await store.setup()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Folder CRUD

    func testCreateFolder() async throws {
        try await store.createFolder(named: "Work")
        let folders = await store.folders()
        XCTAssertEqual(folders, ["Work"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("Work").path))
    }

    func testCreateFolderRejectsDuplicates() async throws {
        try await store.createFolder(named: "Work")
        do {
            try await store.createFolder(named: "Work")
            XCTFail("Should throw on duplicate folder")
        } catch {
            // expected
        }
    }

    func testRenameFolder() async throws {
        try await store.createFolder(named: "Work")
        try await store.renameFolder(from: "Work", to: "Office")
        let folders = await store.folders()
        XCTAssertEqual(folders, ["Office"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("Work").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("Office").path))
    }

    func testDeleteFolder() async throws {
        try await store.createFolder(named: "Work")
        try await store.deleteFolder(named: "Work")
        let folders = await store.folders()
        XCTAssertTrue(folders.isEmpty)
    }

    func testFoldersReturnsSortedTopLevelOnly() async throws {
        try await store.createFolder(named: "Zebra")
        try await store.createFolder(named: "Alpha")
        // Create a subfolder manually — should NOT appear in folders()
        try FileManager.default.createDirectory(
            at: tmpDir.appendingPathComponent("Alpha/SubProject"),
            withIntermediateDirectories: true)
        let folders = await store.folders()
        XCTAssertEqual(folders, ["Alpha", "Zebra"])
    }

    // MARK: - Folder-aware recording scanning

    func testAllRecordingsIncludesSubfolders() async throws {
        try await store.createFolder(named: "Work")
        // Place an MP3 in root
        try Data([0xFF, 0xFB, 0x00]).write(to: tmpDir.appendingPathComponent("root.mp3"))
        // Place an MP3 in Work/
        try Data([0xFF, 0xFB, 0x00]).write(to: tmpDir.appendingPathComponent("Work/meeting.mp3"))

        let all = await store.allRecordings()
        let filenames = Set(all.map(\.filename))
        XCTAssertTrue(filenames.contains("root.mp3"))
        XCTAssertTrue(filenames.contains("Work/meeting.mp3"))
    }

    func testRecordingsInFolder() async throws {
        try await store.createFolder(named: "Work")
        try Data([0xFF, 0xFB, 0x00]).write(to: tmpDir.appendingPathComponent("root.mp3"))
        try Data([0xFF, 0xFB, 0x00]).write(to: tmpDir.appendingPathComponent("Work/meeting.mp3"))

        let workRecs = await store.recordings(inFolder: "Work")
        XCTAssertEqual(workRecs.count, 1)
        XCTAssertEqual(workRecs[0].filename, "Work/meeting.mp3")
    }

    // MARK: - Move recording

    func testMoveRecordingToFolder() async throws {
        try await store.createFolder(named: "Work")
        // Create MP3 + sidecar transcript in root
        try Data([0xFF, 0xFB, 0x00]).write(to: tmpDir.appendingPathComponent("meeting.mp3"))
        try Data("{}".utf8).write(to: tmpDir.appendingPathComponent("meeting.transcript.json"))
        try Data("text".utf8).write(to: tmpDir.appendingPathComponent("meeting.txt"))

        let newFilename = try await store.moveRecording(filename: "meeting.mp3", toFolder: "Work")
        XCTAssertEqual(newFilename, "Work/meeting.mp3")

        // All three files moved
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("Work/meeting.mp3").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("Work/meeting.transcript.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("Work/meeting.txt").path))

        // Originals gone
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("meeting.mp3").path))
    }

    func testMoveRecordingToRoot() async throws {
        try await store.createFolder(named: "Work")
        try Data([0xFF, 0xFB, 0x00]).write(to: tmpDir.appendingPathComponent("Work/meeting.mp3"))

        let newFilename = try await store.moveRecording(filename: "Work/meeting.mp3", toFolder: nil)
        XCTAssertEqual(newFilename, "meeting.mp3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.appendingPathComponent("meeting.mp3").path))
    }

    // MARK: - Folder metadata on RecordingMetadata

    func testRecordingMetadataIncludesFolder() async throws {
        try await store.createFolder(named: "Personal")
        try Data([0xFF, 0xFB, 0x00]).write(to: tmpDir.appendingPathComponent("Personal/memo.mp3"))

        let all = await store.allRecordings()
        let rec = all.first { $0.filename == "Personal/memo.mp3" }
        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.folder, "Personal")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme HiDockKitTests -only-testing:HiDockKitTests/RecordingStoreFolderTests 2>&1 | tail -20`
Expected: Multiple compilation errors — `folders()`, `createFolder(named:)`, `recordings(inFolder:)`, `moveRecording(filename:toFolder:)`, `RecordingMetadata.folder` don't exist yet.

- [ ] **Step 3: Add `folder` property to RecordingMetadata**

```swift
// Sources/HiDockKit/Storage/RecordingMetadata.swift
// Add after fileSizeBytes property:

    /// Folder this recording lives in (relative to library root), or nil for root.
    public let folder: String?

// Update init to include folder parameter:
    public init(
        filename: String,
        recordedAt: Date?,
        mode: String,
        fileSizeBytes: UInt64,
        estimatedDuration: TimeInterval,
        folder: String? = nil
    ) {
        self.filename = filename
        self.recordedAt = recordedAt
        self.mode = mode
        self.fileSizeBytes = fileSizeBytes
        self.estimatedDuration = estimatedDuration
        self.folder = folder
    }
```

- [ ] **Step 4: Add folder operations to RecordingStore**

```swift
// Sources/HiDockKit/Storage/RecordingStore.swift
// Add these methods to the actor:

    /// List top-level folders (sorted alphabetically).
    public func folders() -> [String] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return contents
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// Create a new folder.
    public func createFolder(named name: String) throws {
        let sanitized = Self.sanitizeFilename(name)
        guard !sanitized.isEmpty else { throw HiDockError.invalidFilename(name) }
        let url = baseDirectory.appendingPathComponent(sanitized)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw HiDockError.invalidFilename("Folder '\(name)' already exists")
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    /// Rename a folder.
    public func renameFolder(from oldName: String, to newName: String) throws {
        let sanitized = Self.sanitizeFilename(newName)
        guard !sanitized.isEmpty else { throw HiDockError.invalidFilename(newName) }
        let oldURL = baseDirectory.appendingPathComponent(oldName)
        let newURL = baseDirectory.appendingPathComponent(sanitized)
        try FileManager.default.moveItem(at: oldURL, to: newURL)
    }

    /// Delete a folder and all its contents.
    public func deleteFolder(named name: String) throws {
        let url = baseDirectory.appendingPathComponent(name)
        try FileManager.default.removeItem(at: url)
    }

    /// Move a recording (and its sidecars) to a folder. Pass nil to move to root.
    /// Returns the new relative filename.
    @discardableResult
    public func moveRecording(filename: String, toFolder folder: String?) throws -> String {
        let bareFilename = (filename as NSString).lastPathComponent
        let basename = (bareFilename as NSString).deletingPathExtension

        let destDir: URL
        let newFilename: String
        if let folder {
            destDir = baseDirectory.appendingPathComponent(folder)
            newFilename = "\(folder)/\(bareFilename)"
        } else {
            destDir = baseDirectory
            newFilename = bareFilename
        }

        let fm = FileManager.default
        // Move MP3
        let oldMP3 = baseDirectory.appendingPathComponent(filename)
        let newMP3 = destDir.appendingPathComponent(bareFilename)
        try fm.moveItem(at: oldMP3, to: newMP3)

        // Move sidecars (best effort)
        let sourceDir = oldMP3.deletingLastPathComponent()
        for ext in [".transcript.json", ".txt"] {
            let oldSidecar = sourceDir.appendingPathComponent("\(basename)\(ext)")
            let newSidecar = destDir.appendingPathComponent("\(basename)\(ext)")
            try? fm.moveItem(at: oldSidecar, to: newSidecar)
        }

        return newFilename
    }

    /// Recordings within a specific folder (recursively).
    public func recordings(inFolder folder: String) -> [RecordingMetadata] {
        let folderURL = baseDirectory.appendingPathComponent(folder)
        return scanRecordings(in: folderURL, relativeTo: baseDirectory)
    }
```

- [ ] **Step 5: Update `allRecordings()` to scan recursively with folder metadata**

Replace the existing `allRecordings()` method:

```swift
    /// Scan the directory tree for MP3 files and build metadata from the filesystem.
    public func allRecordings() -> [RecordingMetadata] {
        return scanRecordings(in: baseDirectory, relativeTo: baseDirectory)
    }

    /// Recursive scan helper. Returns recordings with paths relative to `root`.
    private func scanRecordings(in directory: URL, relativeTo root: URL) -> [RecordingMetadata] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        var results: [RecordingMetadata] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "mp3" else { continue }
            guard let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey]) else { continue }

            // Compute relative path from root
            let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let bareFilename = url.lastPathComponent
            let fileSize = UInt64(attrs.fileSize ?? 0)
            let parsed = FilenameParsing.parse(bareFilename)
            let recordedAt = parsed.date ?? attrs.creationDate
            let mode = parsed.mode != .unknown ? parsed.mode.rawValue : ""

            // Extract folder from relative path (nil if in root)
            let folder: String?
            let pathComponents = (relativePath as NSString).deletingLastPathComponent
            folder = pathComponents.isEmpty ? nil : pathComponents

            results.append(RecordingMetadata(
                filename: relativePath,
                recordedAt: recordedAt,
                mode: mode,
                fileSizeBytes: fileSize,
                estimatedDuration: DurationCalculator.estimateDuration(fileSize: fileSize),
                folder: folder
            ))
        }
        return results
    }
```

- [ ] **Step 6: Fix existing RecordingStore callers that don't pass `folder`**

The `storeRecording(hdaData:entry:)` method needs to pass `folder: nil`:

```swift
    // In storeRecording, update the return:
    return RecordingMetadata(
        filename: mp3Filename,
        recordedAt: parsed.date ?? attrs.creationDate,
        mode: parsed.mode != .unknown ? parsed.mode.rawValue : "",
        fileSizeBytes: fileSize,
        estimatedDuration: DurationCalculator.estimateDuration(fileSize: fileSize),
        folder: nil
    )
```

- [ ] **Step 7: Run all tests**

Run: `xcodebuild test -scheme HiDockKitTests 2>&1 | grep -E '(Test Suite|Executed|FAIL)'`
Expected: All tests pass including new `RecordingStoreFolderTests`.

- [ ] **Step 8: Commit**

```bash
git add Sources/HiDockKit/Storage/RecordingStore.swift Sources/HiDockKit/Storage/RecordingMetadata.swift Tests/HiDockKitTests/RecordingStoreFolderTests.swift
git commit -m "feat: folder-aware RecordingStore with CRUD, move, recursive scan"
```

---

## Task 2: TranscriptStore — Coalesced TXT Writes

Add debounced TXT regeneration and stale-TXT detection to `TranscriptStore`.

**Files:**
- Modify: `Sources/HiDockKit/Transcription/TranscriptStore.swift`
- Create: `Tests/HiDockKitTests/TranscriptStoreDebouncedTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/HiDockKitTests/TranscriptStoreDebouncedTests.swift
import XCTest
@testable import HiDockKit

final class TranscriptStoreDebouncedTests: XCTestCase {

    var tmpDir: URL!
    var store: TranscriptStore!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = TranscriptStore(baseDirectory: tmpDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeTranscript(filename: String = "test.mp3") -> Transcript {
        Transcript(
            recordingFilename: filename,
            transcriptionModel: "test",
            hasSpeakerLabels: true,
            segments: [
                .init(startTime: 0, endTime: 5, text: "Hello.", speakerID: "S1"),
                .init(startTime: 5, endTime: 10, text: "World.", speakerID: "S2"),
            ],
            speakerNames: ["S1": "Alice", "S2": "Bob"]
        )
    }

    func testSpeakerUpdateWritesJSONImmediately() async throws {
        let t = makeTranscript()
        try await store.save(t, mp3Filename: "test.mp3")

        try await store.updateSpeakerNames(for: "test.mp3", names: ["S1": "Carol", "S2": "Bob"])

        // JSON should be updated immediately
        let loaded = await store.transcript(for: "test.mp3")
        XCTAssertEqual(loaded?.speakerNames["S1"], "Carol")
    }

    func testTxtRegeneratedAfterFlush() async throws {
        let t = makeTranscript()
        try await store.save(t, mp3Filename: "test.mp3")

        try await store.updateSpeakerNames(for: "test.mp3", names: ["S1": "Carol", "S2": "Bob"])

        // Flush pending TXT writes
        await store.flushPendingTxtWrites()

        let txtURL = tmpDir.appendingPathComponent("test.txt")
        let txtContent = try String(contentsOf: txtURL, encoding: .utf8)
        XCTAssertTrue(txtContent.contains("Carol"))
    }

    func testStaleTxtDetectedOnLoad() async throws {
        let t = makeTranscript()
        try await store.save(t, mp3Filename: "test.mp3")
        await store.flushPendingTxtWrites()

        // Manually make TXT older than JSON
        let txtURL = tmpDir.appendingPathComponent("test.txt")
        let jsonURL = tmpDir.appendingPathComponent("test.transcript.json")

        // Touch JSON to be newer
        try "".write(to: txtURL, atomically: true, encoding: .utf8) // stale content
        let past = Date().addingTimeInterval(-10)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: txtURL.path)

        // Reload — should detect stale TXT
        let store2 = TranscriptStore(baseDirectory: tmpDir)
        try await store2.loadAll()
        await store2.flushPendingTxtWrites()

        let refreshed = try String(contentsOf: txtURL, encoding: .utf8)
        XCTAssertTrue(refreshed.contains("Alice")) // regenerated with correct names
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme HiDockKitTests -only-testing:HiDockKitTests/TranscriptStoreDebouncedTests 2>&1 | tail -20`
Expected: Compilation error — `flushPendingTxtWrites()` doesn't exist.

- [ ] **Step 3: Add coalesced TXT write support to TranscriptStore**

```swift
// Sources/HiDockKit/Transcription/TranscriptStore.swift
// Add these properties to the actor:

    private var dirtyTxtFiles: Set<String> = []  // mp3Filenames needing TXT regeneration
    private var txtFlushTask: Task<Void, Never>?

// Replace the body of updateSpeakerNames:
    public func updateSpeakerNames(for mp3Filename: String, names: [String: String]) throws {
        guard var transcript = cache[mp3Filename] else { return }
        transcript.speakerNames = names
        try save(transcript, mp3Filename: mp3Filename)
        markTxtDirty(mp3Filename)
    }

// Replace the body of mergeSpeakers:
    public func mergeSpeakers(for mp3Filename: String, source sourceID: String, into targetID: String) throws {
        guard var transcript = cache[mp3Filename] else { return }
        transcript.segments = transcript.segments.map { seg in
            guard seg.speakerID == sourceID else { return seg }
            return Transcript.Segment(
                id: seg.id, startTime: seg.startTime, endTime: seg.endTime,
                text: seg.text, speakerID: targetID, confidence: seg.confidence
            )
        }
        transcript.speakerNames.removeValue(forKey: sourceID)
        try save(transcript, mp3Filename: mp3Filename)
        markTxtDirty(mp3Filename)
    }

// Add debounce methods:
    private func markTxtDirty(_ mp3Filename: String) {
        dirtyTxtFiles.insert(mp3Filename)
        txtFlushTask?.cancel()
        txtFlushTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await flushPendingTxtWrites()
        }
    }

    /// Flush all pending TXT regenerations immediately.
    public func flushPendingTxtWrites() {
        txtFlushTask?.cancel()
        txtFlushTask = nil
        for mp3Filename in dirtyTxtFiles {
            if let transcript = cache[mp3Filename] {
                try? exportPlainText(transcript, mp3Filename: mp3Filename)
            }
        }
        dirtyTxtFiles.removeAll()
    }
```

- [ ] **Step 4: Add stale TXT detection to loadAll()**

At the end of `loadAll()`, after the existing loop, add:

```swift
        // Detect and regenerate stale TXT files
        for (mp3Key, transcript) in cache {
            let basename = (mp3Key as NSString).deletingPathExtension
            let jsonURL = baseDirectory.appendingPathComponent("\(basename).transcript.json")
            let txtURL = baseDirectory.appendingPathComponent("\(basename).txt")

            guard FileManager.default.fileExists(atPath: txtURL.path) else {
                // No TXT at all — mark dirty
                dirtyTxtFiles.insert(mp3Key)
                continue
            }

            let jsonMod = (try? FileManager.default.attributesOfItem(atPath: jsonURL.path)[.modificationDate] as? Date) ?? .distantPast
            let txtMod = (try? FileManager.default.attributesOfItem(atPath: txtURL.path)[.modificationDate] as? Date) ?? .distantFuture

            if jsonMod > txtMod {
                dirtyTxtFiles.insert(mp3Key)
            }
        }

        // Flush any stale TXTs found
        if !dirtyTxtFiles.isEmpty {
            flushPendingTxtWrites()
        }
```

- [ ] **Step 5: Run all tests**

Run: `xcodebuild test -scheme HiDockKitTests 2>&1 | grep -E '(Test Suite|Executed|FAIL)'`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/HiDockKit/Transcription/TranscriptStore.swift Tests/HiDockKitTests/TranscriptStoreDebouncedTests.swift
git commit -m "feat: coalesced TXT writes with debounce timer and stale detection on load"
```

---

## Task 3: PlaybackState — Extracted and Responsive

Extract playback logic from `AppState` into a standalone `@Observable @MainActor` class. Replace `Timer` polling with `AVPlayer.addPeriodicTimeObserver`. Fix seek latency.

**Files:**
- Create: `Sources/DockTape/State/PlaybackState.swift`

- [ ] **Step 1: Create PlaybackState**

```swift
// Sources/DockTape/State/PlaybackState.swift
import SwiftUI
import AVFoundation

/// Isolated playback state — only views reading these properties re-render on 4Hz updates.
@Observable
@MainActor
final class PlaybackState {
    var playingFile: String?
    var isPlaying: Bool = false
    var progress: Double = 0
    var duration: Double = 0
    var rate: Float = 1.0

    private var avPlayer: AVPlayer?
    private var timeObserverToken: Any?
    private var endOfPlaybackObserver: NSObjectProtocol?

    /// The currently active segment index, derived from progress and segment timestamps.
    /// Changes infrequently (~every 10-15s) — views that read this don't re-render on every tick.
    var activeSegmentIndex: Int?
    private var segmentTimestamps: [TimeInterval] = []

    static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

    /// Provide transcript segment start times so activeSegmentIndex can be computed.
    func setSegmentTimestamps(_ timestamps: [TimeInterval]) {
        segmentTimestamps = timestamps
        updateActiveSegment()
    }

    /// Start playing a file at the given URL.
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

        // Get duration once asset is ready
        Task {
            if let dur = try? await playerItem.asset.load(.duration), dur.isNumeric {
                self.duration = CMTimeGetSeconds(dur)
            }
        }

        // Pipeline-synchronized progress updates (replaces Timer.scheduledTimer)
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = CMTimeGetSeconds(time)
                if t.isFinite {
                    self.progress = t
                    self.updateActiveSegment()
                }
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
        if let token = timeObserverToken {
            avPlayer?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let obs = endOfPlaybackObserver {
            NotificationCenter.default.removeObserver(obs)
            endOfPlaybackObserver = nil
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
        // Default tolerances for responsive scrubbing (no sample-accurate seek)
        avPlayer?.seek(to: cmTime)
        progress = time
        updateActiveSegment()
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        if isPlaying {
            avPlayer?.rate = newRate
        }
    }

    // MARK: - Active Segment

    private func updateActiveSegment() {
        guard !segmentTimestamps.isEmpty else {
            if activeSegmentIndex != nil { activeSegmentIndex = nil }
            return
        }
        // Binary search for the segment whose start time is <= progress
        var lo = 0, hi = segmentTimestamps.count - 1
        var result = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if segmentTimestamps[mid] <= progress {
                result = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        if activeSegmentIndex != result {
            activeSegmentIndex = result
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild build -scheme DockTape 2>&1 | tail -5`
Expected: Build succeeds (PlaybackState is created but not yet wired in).

- [ ] **Step 3: Commit**

```bash
git add Sources/DockTape/State/PlaybackState.swift
git commit -m "feat: extract PlaybackState with AVPlayer time observer and active segment tracking"
```

---

## Task 4: TranscriptionState — Extracted

Extract transcription logic from `AppState`.

**Files:**
- Create: `Sources/DockTape/State/TranscriptionState.swift`

- [ ] **Step 1: Create TranscriptionState**

```swift
// Sources/DockTape/State/TranscriptionState.swift
import SwiftUI
import HiDockKit

/// Isolated transcription state.
@Observable
@MainActor
final class TranscriptionState {
    var transcribingFile: String?
    var phase: String = ""
    var queue: [RecordingMetadata] = []
    var queueIndex: Int = 0
    var startTime: Date?
    var statuses: [String: TranscriptStatus] = [:]

    private var transcriptionTask: Task<Void, Never>?
    private var pipeline: RecordingPipeline?

    let transcriptStore: TranscriptStore

    init(transcriptStore: TranscriptStore) {
        self.transcriptStore = transcriptStore
    }

    var isTranscribing: Bool { transcribingFile != nil }

    func transcribe(
        recordings: [RecordingMetadata],
        baseDirectory: URL,
        onStatusMessage: @escaping (String) -> Void,
        onError: @escaping (String) -> Void,
        onComplete: @escaping () async -> Void
    ) async {
        let existingFilenames = Set(queue.map(\.filename))
        let newRecs = recordings.filter { !existingFilenames.contains($0.filename) }
        queue.append(contentsOf: newRecs)

        for rec in newRecs {
            statuses[rec.filename] = .inProgress
        }

        guard transcriptionTask == nil else { return }
        startTime = Date()

        let task = Task {
            do {
                if pipeline == nil {
                    phase = "Loading models (first time takes ~1 min)..."
                    onStatusMessage(phase)
                    pipeline = RecordingPipeline(baseDirectory: baseDirectory)
                    try await pipeline!.setup()
                }

                while queueIndex < queue.count {
                    try Task.checkCancellation()

                    let index = queueIndex
                    let rec = queue[index]
                    let total = queue.count

                    transcribingFile = rec.filename
                    statuses[rec.filename] = .inProgress
                    startTime = Date()
                    let progress = total > 1 ? " (\(index + 1)/\(total))" : ""
                    phase = "Transcribing\(progress)..."
                    onStatusMessage("Transcribing \(rec.filename)\(progress)...")

                    try? await transcriptStore.delete(for: rec.filename)
                    let transcript = try await pipeline!.transcribeRecording(filename: rec.filename)
                    try Task.checkCancellation()

                    try? await transcriptStore.save(transcript, mp3Filename: rec.filename)
                    statuses[rec.filename] = .done
                    queueIndex += 1
                }

                let count = queue.count
                onStatusMessage(count == 1 ? "Transcription complete" : "Transcribed \(count) recordings")
                resetState()
                await onComplete()
            } catch is CancellationError {
                if let file = transcribingFile {
                    statuses[file] = TranscriptStatus.none
                }
                onStatusMessage("Transcription cancelled")
                resetState()
            } catch {
                if let file = transcribingFile {
                    statuses[file] = .failed
                }
                onError("Transcription failed: \(error.localizedDescription)")
                onStatusMessage("Transcription failed")
                resetState()
            }
        }
        transcriptionTask = task
    }

    func cancel() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        if let file = transcribingFile {
            statuses[file] = TranscriptStatus.none
        }
        for rec in queue.dropFirst(queueIndex + 1) {
            statuses[rec.filename] = TranscriptStatus.none
        }
        resetState()
    }

    private func resetState() {
        transcribingFile = nil
        phase = ""
        queue = []
        queueIndex = 0
        startTime = nil
        transcriptionTask = nil
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild build -scheme DockTape 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/DockTape/State/TranscriptionState.swift
git commit -m "feat: extract TranscriptionState from AppState"
```

---

## Task 5: LibraryState and DeviceState — Extracted

Extract library and device management from `AppState`.

**Files:**
- Create: `Sources/DockTape/State/LibraryState.swift`
- Create: `Sources/DockTape/State/DeviceState.swift`

- [ ] **Step 1: Create LibraryState**

```swift
// Sources/DockTape/State/LibraryState.swift
import SwiftUI
import HiDockKit

/// Library state: recordings, folders, selection.
@Observable
@MainActor
final class LibraryState {
    var recordings: [RecordingMetadata] = []
    var folders: [String] = []
    var selectedFolder: String? = nil  // nil = "All Recordings"
    var selectedRecording: String? = nil
    var selectedRecordings: Set<String> = []
    var downloadedFilenames: Set<String> = []
    var isSearchFocused: Bool = false

    let store: RecordingStore
    let transcriptStore: TranscriptStore

    init(store: RecordingStore, transcriptStore: TranscriptStore) {
        self.store = store
        self.transcriptStore = transcriptStore
    }

    func setup() async throws {
        try await store.setup()
        try await transcriptStore.loadAll()
        await refresh()
    }

    func refresh() async {
        recordings = await store.allRecordings()
        downloadedFilenames = Set(recordings.map(\.filename))
        folders = await store.folders()
        try? await transcriptStore.loadAll()
    }

    func isDownloaded(_ filename: String) -> Bool {
        let mp3Name = filename.hasSuffix(".hda")
            ? filename.replacingOccurrences(of: ".hda", with: ".mp3", options: .caseInsensitive)
            : filename
        return downloadedFilenames.contains(mp3Name)
    }

    /// Recordings filtered by the currently selected folder.
    var filteredByFolder: [RecordingMetadata] {
        guard let folder = selectedFolder else { return recordings }
        return recordings.filter { $0.folder == folder || ($0.folder?.hasPrefix(folder + "/") == true) }
    }

    // MARK: - Folder CRUD

    func createFolder(named name: String) async throws {
        try await store.createFolder(named: name)
        folders = await store.folders()
    }

    func renameFolder(from oldName: String, to newName: String) async throws {
        try await store.renameFolder(from: oldName, to: newName)
        if selectedFolder == oldName { selectedFolder = newName }
        await refresh()
    }

    func deleteFolder(named name: String) async throws {
        try await store.deleteFolder(named: name)
        if selectedFolder == name { selectedFolder = nil }
        await refresh()
    }

    func moveRecording(filename: String, toFolder folder: String?) async throws {
        let newFilename = try await store.moveRecording(filename: filename, toFolder: folder)
        await transcriptStore.rename(from: filename, to: newFilename)
        await refresh()
    }

    func deleteRecording(_ rec: RecordingMetadata) async throws {
        try await store.deleteRecording(filename: rec.filename)
        try await transcriptStore.delete(for: rec.filename)
        await refresh()
    }

    func renameRecording(_ rec: RecordingMetadata, to name: String) async throws -> String {
        let newFilename = try await store.renameRecording(filename: rec.filename, to: name)
        await transcriptStore.rename(from: rec.filename, to: newFilename)
        await refresh()
        return newFilename
    }

    func revealInFinder(_ rec: RecordingMetadata) {
        let url = store.baseDirectory.appendingPathComponent(rec.filename)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func hasTranscript(for filename: String) async -> Bool {
        await transcriptStore.hasTranscript(for: filename)
    }

    func transcript(for filename: String) async -> Transcript? {
        await transcriptStore.transcript(for: filename)
    }

    func updateSpeakerNames(for filename: String, names: [String: String]) async throws {
        // Detect merges (same name assigned to multiple IDs)
        var nameToIDs: [String: [String]] = [:]
        for (sid, name) in names {
            nameToIDs[name, default: []].append(sid)
        }
        for (_, ids) in nameToIDs where ids.count > 1 {
            let sorted = ids.sorted()
            let targetID = sorted[0]
            for sourceID in sorted.dropFirst() {
                try await transcriptStore.mergeSpeakers(for: filename, source: sourceID, into: targetID)
            }
        }
        let current = await transcriptStore.transcript(for: filename)
        if let current {
            var finalNames: [String: String] = [:]
            for sid in current.speakerIDs {
                finalNames[sid] = names[sid] ?? sid
            }
            try await transcriptStore.updateSpeakerNames(for: filename, names: finalNames)
        }
    }
}
```

- [ ] **Step 2: Create DeviceState**

```swift
// Sources/DockTape/State/DeviceState.swift
import SwiftUI
import HiDockKit

/// Device connection and file management state.
@Observable
@MainActor
final class DeviceState {
    var model: DeviceModel?
    var isConnected: Bool = false
    var statusMessage: String = "No device connected"
    var downloadingFiles: Set<String> = []
    var deletingFiles: Set<String> = []
    var selectedDeviceFile: String? = nil
    var selectedDeviceFiles: Set<String> = []
    var showDeviceInfo: Bool = false
    var isSyncing: Bool = false
    var isFormattingCard: Bool = false

    var deviceManager: DeviceManager?
    var syncEngine: SyncEngine?
    var usbConnection: USBConnection?

    var files: [FileEntry] {
        model?.files ?? []
    }

    func refreshDevice() async {
        guard let mgr = deviceManager else { return }
        _ = try? await mgr.queryBattery()
        _ = try? await mgr.queryCardInfo()
        _ = try? await mgr.queryFileList()
    }

    func downloadFile(_ file: FileEntry) async throws {
        guard let engine = syncEngine else { return }
        downloadingFiles.insert(file.filename)
        defer { downloadingFiles.remove(file.filename) }
        _ = try await engine.downloadFile(file)
    }

    func deleteFromDevice(_ file: FileEntry) async throws {
        guard let mgr = deviceManager else { return }
        deletingFiles.insert(file.filename)
        defer { deletingFiles.remove(file.filename) }
        try await mgr.deleteFile(entry: file)
        _ = try await mgr.queryFileList()
    }

    func syncAll(
        deleteAfterDownload: Bool,
        onProgress: @escaping (SyncEngine.SyncProgress) -> Void
    ) async throws -> SyncEngine.SyncResult {
        guard let engine = syncEngine else {
            throw HiDockError.transferFailed("No sync engine")
        }
        return try await engine.syncAll(deleteAfterDownload: deleteAfterDownload, onProgress: onProgress)
    }

    func syncClock() async throws {
        guard let mgr = deviceManager else { return }
        try await mgr.syncTime()
        _ = try? await mgr.queryTime()
    }

    func formatCard() async throws {
        guard let mgr = deviceManager else { return }
        isFormattingCard = true
        defer { isFormattingCard = false }
        try await mgr.formatCard()
    }

    func updateSettings(_ settings: DeviceSettings) async throws {
        guard let mgr = deviceManager else { return }
        try await mgr.updateSettings(settings)
    }

    func refreshDeviceTime() async {
        guard let mgr = deviceManager else { return }
        _ = try? await mgr.queryTime()
    }

    func cleanup() async {
        if let mgr = deviceManager {
            await mgr.disconnect()
        }
        await usbConnection?.close()
        deviceManager = nil
        syncEngine = nil
        usbConnection = nil
        model = nil
        isConnected = false
    }
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild build -scheme DockTape 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/DockTape/State/LibraryState.swift Sources/DockTape/State/DeviceState.swift
git commit -m "feat: extract LibraryState and DeviceState from AppState"
```

---

## Task 6: AppState — Rewrite as Thin Coordinator

Gut `AppState` to a thin coordinator that holds the four sub-objects and handles cross-cutting actions + device monitoring.

**Files:**
- Modify: `Sources/DockTape/AppState.swift`

- [ ] **Step 1: Rewrite AppState**

Replace the entire contents of `AppState.swift` with the coordinator:

```swift
// Sources/DockTape/AppState.swift
import SwiftUI
import AVFoundation
import HiDockKit

enum SidebarSelection: Hashable {
    case allRecordings
    case folder(String)
    case device
}

enum TranscriptStatus {
    case none
    case inProgress
    case done
    case failed
}

/// Thin coordinator that owns sub-state objects and handles cross-cutting actions.
@Observable
@MainActor
final class AppState {
    let library: LibraryState
    let device: DeviceState
    let playback: PlaybackState
    let transcription: TranscriptionState

    var selectedView: SidebarSelection = .allRecordings
    var errorMessage: String?
    var statusMessage: String = "No device connected"

    // Settings (persisted to UserDefaults)
    var autoDeleteAfterDownload: Bool = false {
        didSet { UserDefaults.standard.set(autoDeleteAfterDownload, forKey: "autoDeleteAfterDownload") }
    }
    var autoSyncClock: Bool = true {
        didSet { UserDefaults.standard.set(autoSyncClock, forKey: "autoSyncClock") }
    }

    private let monitor = USBDeviceMonitor()
    private var isConnecting: Bool = false
    private var pollingTask: Task<Void, Never>?

    init() {
        let customPath = UserDefaults.standard.url(forKey: "libraryLocation")
        let store = RecordingStore(baseDirectory: customPath)
        let transcriptStore = TranscriptStore(baseDirectory: store.baseDirectory)

        self.library = LibraryState(store: store, transcriptStore: transcriptStore)
        self.device = DeviceState()
        self.playback = PlaybackState()
        self.transcription = TranscriptionState(transcriptStore: transcriptStore)

        self.autoDeleteAfterDownload = UserDefaults.standard.bool(forKey: "autoDeleteAfterDownload")
        self.autoSyncClock = UserDefaults.standard.object(forKey: "autoSyncClock") as? Bool ?? true
    }

    func setup() async throws {
        try await library.setup()
    }

    // MARK: - Cross-cutting actions

    func downloadFile(_ file: FileEntry) async {
        do {
            try await device.downloadFile(file)
            await library.refresh()
            statusMessage = "Downloaded \(file.filename)"
        } catch {
            errorMessage = "Download failed: \(error.localizedDescription)"
        }
    }

    func syncAll() async {
        device.isSyncing = true
        do {
            let result = try await device.syncAll(
                deleteAfterDownload: autoDeleteAfterDownload
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.statusMessage = "Downloading \(progress.currentFile)..."
                }
            }
            device.isSyncing = false
            await library.refresh()

            if result.downloaded.isEmpty && result.failed.isEmpty {
                statusMessage = "Already up to date"
            } else {
                var msg = "Downloaded \(result.downloaded.count) file(s)"
                if !result.failed.isEmpty { msg += ", \(result.failed.count) failed" }
                statusMessage = msg
            }
        } catch {
            device.isSyncing = false
            errorMessage = error.localizedDescription
            statusMessage = "Sync failed"
        }
    }

    func deleteLocalRecording(_ rec: RecordingMetadata) async {
        // Stop playback if this file is playing
        if playback.playingFile == rec.filename {
            playback.stop()
        }
        do {
            try await library.deleteRecording(rec)
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    func deleteFromDevice(_ file: FileEntry) async {
        do {
            try await device.deleteFromDevice(file)
            statusMessage = "Deleted \(file.filename) from device"
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    func playRecording(_ rec: RecordingMetadata) {
        let url = library.store.baseDirectory.appendingPathComponent(rec.filename)
        playback.play(file: rec.filename, url: url)
    }

    func transcribeRecordings(_ recs: [RecordingMetadata]) async {
        await transcription.transcribe(
            recordings: recs,
            baseDirectory: library.store.baseDirectory,
            onStatusMessage: { [weak self] msg in self?.statusMessage = msg },
            onError: { [weak self] msg in self?.errorMessage = msg },
            onComplete: { [weak self] in await self?.library.refresh() }
        )
    }

    func renameRecording(_ rec: RecordingMetadata, to name: String) async {
        do {
            let newFilename = try await library.renameRecording(rec, to: name)
            if playback.playingFile == rec.filename { playback.playingFile = newFilename }
            if transcription.transcribingFile == rec.filename { transcription.transcribingFile = newFilename }
        } catch {
            errorMessage = "Rename failed: \(error.localizedDescription)"
        }
    }

    func updateSpeakerNames(for filename: String, names: [String: String]) async {
        do {
            try await library.updateSpeakerNames(for: filename, names: names)
        } catch {
            errorMessage = "Failed to save speaker names: \(error.localizedDescription)"
        }
    }

    // MARK: - Device Monitoring

    func startMonitoring() {
        monitor.start(
            onConnect: { [weak self] usbDevice in
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    await self?.handleDeviceConnected(usbDevice)
                }
            },
            onDisconnect: { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handleDeviceDisconnected()
                }
            }
        )
        Task {
            let devices = USBDeviceMonitor.findConnectedDevices()
            if let first = devices.first {
                await handleDeviceConnected(first)
            }
        }
    }

    func stopMonitoring() {
        monitor.stop()
    }

    private func handleDeviceConnected(_ usbDevice: USBDeviceMonitor.USBDevice) async {
        guard !device.isConnected && !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }

        await device.cleanup()
        statusMessage = "Connecting to \(usbDevice.model.rawValue)..."

        let delays: [Duration] = [.zero, .seconds(2), .seconds(3)]
        var lastError: Error?

        for (attempt, delay) in delays.enumerated() {
            if attempt > 0 {
                await device.cleanup()
                statusMessage = "Retrying connection (attempt \(attempt + 1)/\(delays.count))..."
                try? await Task.sleep(for: delay)
            }

            let model = DeviceModel(id: "\(usbDevice.vendorID):\(usbDevice.productID)", model: usbDevice.model)
            device.model = model

            do {
                let conn = USBConnection(vendorID: usbDevice.vendorID, productID: usbDevice.productID)
                try conn.open()
                device.usbConnection = conn

                let mgr = DeviceManager(device: model)
                await mgr.connect(via: conn)
                device.deviceManager = mgr
                device.syncEngine = SyncEngine(deviceManager: mgr, store: library.store)

                _ = try await mgr.queryDeviceInfo()
                _ = try await mgr.queryBattery()
                _ = try await mgr.queryCardInfo()
                _ = try await mgr.queryFileList()
                _ = try await mgr.querySettings()

                device.isConnected = true
                statusMessage = "\(model.model.rawValue) connected"
                errorMessage = nil

                if autoSyncClock { try? await mgr.syncTime() }
                startPolling()
                return
            } catch {
                lastError = error
            }
        }

        errorMessage = "Connection failed: \(lastError?.localizedDescription ?? "unknown error")"
        statusMessage = "Connection failed"
        await device.cleanup()
    }

    private func handleDeviceDisconnected() async {
        stopPolling()
        await device.cleanup()
        statusMessage = "Device disconnected"
        selectedView = .allRecordings
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, device.deviceManager != nil else { break }
                guard !device.isSyncing, device.downloadingFiles.isEmpty, !device.isFormattingCard else { continue }
                await device.refreshDevice()
                await library.refresh()
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Settings Actions

    func syncClock() async {
        do {
            try await device.syncClock()
            statusMessage = "Clock synced"
        } catch {
            errorMessage = "Clock sync failed: \(error.localizedDescription)"
        }
    }

    func formatCard() async {
        do {
            try await device.formatCard()
            statusMessage = "Card formatted"
        } catch {
            errorMessage = "Format failed: \(error.localizedDescription)"
        }
    }

    func updateDeviceSettings(_ settings: DeviceSettings) async {
        do {
            try await device.updateSettings(settings)
        } catch {
            errorMessage = "Settings update failed: \(error.localizedDescription)"
        }
    }

    func refreshDeviceTime() async {
        await device.refreshDeviceTime()
    }
}
```

- [ ] **Step 2: Build — expect errors from views still referencing old AppState API**

Run: `xcodebuild build -scheme DockTape 2>&1 | grep error: | head -20`
Expected: Errors in ContentView, RecordingListView, DeviceFilesView, etc. This is expected — we'll fix these in the next tasks.

- [ ] **Step 3: Commit (with build errors noted)**

```bash
git add Sources/DockTape/AppState.swift
git commit -m "refactor: rewrite AppState as thin coordinator over 4 sub-objects

Build is intentionally broken — view files still reference old API.
Will be fixed in subsequent tasks."
```

---

## Task 7: SidebarView — Column 1

Create the new sidebar with Library folders section and Device section.

**Files:**
- Create: `Sources/DockTape/Views/SidebarView.swift`

- [ ] **Step 1: Create SidebarView**

```swift
// Sources/DockTape/Views/SidebarView.swift
import SwiftUI
import HiDockKit

struct SidebarView: View {
    @Bindable var state: AppState

    @State private var renamingFolder: String? = nil
    @State private var renameText: String = ""
    @State private var isCreatingFolder: Bool = false
    @State private var newFolderName: String = ""

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $state.selectedView) {
                Section("Library") {
                    Label {
                        HStack {
                            Text("All Recordings")
                            Spacer()
                            if state.library.recordings.count > 0 {
                                Text("\(state.library.recordings.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary)
                                    .clipShape(Capsule())
                            }
                        }
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .tag(SidebarSelection.allRecordings)

                    ForEach(state.library.folders, id: \.self) { folder in
                        Label {
                            HStack {
                                if renamingFolder == folder {
                                    TextField("Folder name", text: $renameText)
                                        .textFieldStyle(.roundedBorder)
                                        .onSubmit { commitRename(oldName: folder) }
                                        .onExitCommand { renamingFolder = nil }
                                } else {
                                    Text(folder)
                                }
                                Spacer()
                                let count = state.library.recordings.filter { $0.folder == folder }.count
                                if count > 0 {
                                    Text("\(count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.quaternary)
                                        .clipShape(Capsule())
                                }
                            }
                        } icon: {
                            Image(systemName: "folder")
                        }
                        .tag(SidebarSelection.folder(folder))
                        .contextMenu {
                            Button("Rename...") {
                                renameText = folder
                                renamingFolder = folder
                            }
                            Divider()
                            Button("Delete Folder", role: .destructive) {
                                Task {
                                    do { try await state.library.deleteFolder(named: folder) }
                                    catch { state.errorMessage = error.localizedDescription }
                                }
                            }
                        }
                        .dropDestination(for: String.self) { filenames, _ in
                            Task {
                                for filename in filenames {
                                    try? await state.library.moveRecording(filename: filename, toFolder: folder)
                                }
                            }
                            return true
                        }
                    }
                }

                if state.device.isConnected, let device = state.device.model {
                    Section("Device") {
                        Label {
                            HStack {
                                Text("HiDock \(device.model.rawValue)")
                                Spacer()
                                Text("\(device.files.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary)
                                    .clipShape(Capsule())
                            }
                        } icon: {
                            Image(systemName: "waveform")
                        }
                        .tag(SidebarSelection.device)
                    }
                }
            }
            .listStyle(.sidebar)

            // Folder creation button
            HStack {
                Button {
                    isCreatingFolder = true
                    newFolderName = ""
                } label: {
                    Label("New Folder", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Divider()
            deviceStatusBar
        }
        .frame(minWidth: 200)
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                guard !newFolderName.isEmpty else { return }
                Task {
                    do { try await state.library.createFolder(named: newFolderName) }
                    catch { state.errorMessage = error.localizedDescription }
                }
            }
        } message: {
            Text("Enter a name for the new folder.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await state.library.refresh() }
        }
    }

    private func commitRename(oldName: String) {
        let newName = renameText.trimmingCharacters(in: .whitespaces)
        renamingFolder = nil
        guard !newName.isEmpty, newName != oldName else { return }
        Task {
            do { try await state.library.renameFolder(from: oldName, to: newName) }
            catch { state.errorMessage = error.localizedDescription }
        }
    }

    // MARK: - Device Status Bar

    @ViewBuilder
    private var deviceStatusBar: some View {
        if state.device.isConnected, let device = state.device.model {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                        .accessibilityLabel("Connected")
                    Text("HiDock \(device.model.rawValue)")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Button {
                        state.device.showDeviceInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Device Info")
                }

                if let battery = device.battery {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: battery.isCharging ? "bolt.fill" : "battery.100")
                                .font(.caption2).foregroundStyle(batteryColor(battery.level))
                            Text("Battery").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(battery.level)%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(battery.level), total: 100)
                            .tint(batteryColor(battery.level)).controlSize(.small)
                            .accessibilityLabel("Battery level")
                            .accessibilityValue("\(battery.level) percent")
                    }
                }

                if let card = device.cardInfo, card.isInserted {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: "internaldrive")
                                .font(.caption2).foregroundStyle(storageColor(card.usagePercent))
                            Text("Storage").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            let freeGB = Double(card.freeBytes) / 1_073_741_824
                            let totalGB = Double(card.totalBytes) / 1_073_741_824
                            Text(String(format: "%.1f / %.1f GB", freeGB, totalGB))
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        ProgressView(value: card.usagePercent, total: 100)
                            .tint(storageColor(card.usagePercent)).controlSize(.small)
                            .accessibilityLabel("Storage used")
                            .accessibilityValue(String(format: "%.0f percent", card.usagePercent))
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        } else {
            HStack(spacing: 6) {
                Circle().fill(.secondary.opacity(0.5)).frame(width: 8, height: 8)
                    .accessibilityLabel("Disconnected")
                Text("No device connected").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private func batteryColor(_ level: Int) -> Color {
        switch level {
        case 51...100: .green
        case 21...50: .yellow
        default: .red
        }
    }

    private func storageColor(_ percent: Double) -> Color {
        switch percent {
        case 90...: .red
        case 75..<90: .orange
        default: .green
        }
    }
}
```

- [ ] **Step 2: Build to check compilation (may still have errors from other views)**

Run: `xcodebuild build -scheme DockTape 2>&1 | grep "SidebarView" | head -10`
Expected: No errors from SidebarView itself.

- [ ] **Step 3: Commit**

```bash
git add Sources/DockTape/Views/SidebarView.swift
git commit -m "feat: SidebarView with real filesystem folders, device section, drop targets"
```

---

## Task 8: RecordingListPane, DetailPane, InfoTabView, MultiSelectSummary — Columns 2 & 3

Create the middle and right pane views. This is the largest task — it creates 4 files and wires up the progressive tab system.

**Files:**
- Create: `Sources/DockTape/Views/RecordingListPane.swift`
- Create: `Sources/DockTape/Views/DetailPane.swift`
- Create: `Sources/DockTape/Views/InfoTabView.swift`
- Create: `Sources/DockTape/Views/MultiSelectSummary.swift`

- [ ] **Step 1: Create RecordingListPane (Column 2)**

```swift
// Sources/DockTape/Views/RecordingListPane.swift
import SwiftUI
import HiDockKit

struct RecordingListPane: View {
    @Bindable var state: AppState
    @State private var searchText = ""
    @AppStorage("librarySortBy") private var sortBy: LibrarySort = .dateNewest
    @AppStorage("libraryFilterMode") private var filterMode: String = ""
    @AppStorage("libraryFilterPeriod") private var filterPeriod: TimePeriod = .anyTime

    enum TimePeriod: String, CaseIterable {
        case anyTime = "Any Time"
        case today = "Today"
        case last7Days = "Last 7 Days"
        case last30Days = "Last 30 Days"

        var startDate: Date? {
            let cal = Calendar.current
            switch self {
            case .anyTime: return nil
            case .today: return cal.startOfDay(for: Date())
            case .last7Days: return cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: Date()))
            case .last30Days: return cal.date(byAdding: .day, value: -30, to: cal.startOfDay(for: Date()))
            }
        }
    }

    enum LibrarySort: String, CaseIterable {
        case dateNewest = "Newest First"
        case dateOldest = "Oldest First"
        case longest = "Longest First"
        case shortest = "Shortest First"
    }

    var body: some View {
        Group {
            switch state.selectedView {
            case .allRecordings, .folder:
                libraryContent
            case .device:
                deviceContent
            }
        }
        .searchable(text: $searchText, prompt: "Search")
        .modifier(SearchFocusModifier(trigger: $state.library.isSearchFocused))
    }

    // MARK: - Library Content

    @ViewBuilder
    private var libraryContent: some View {
        let recs = filteredRecordings
        if state.library.recordings.isEmpty {
            ContentUnavailableView {
                Label("No Recordings", systemImage: "waveform.slash")
            } description: {
                Text("Download recordings from your device to get started.")
            }
        } else if recs.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List(selection: $state.library.selectedRecordings) {
                ForEach(recs) { rec in
                    LibraryRow(
                        recording: rec,
                        transcriptStatus: state.transcription.statuses[rec.filename] ?? .none,
                        isTranscribing: state.transcription.transcribingFile == rec.filename,
                        isCurrentlyPlaying: state.playback.playingFile == rec.filename && state.playback.isPlaying
                    )
                    .tag(rec.filename)
                    .draggable(rec.filename)
                    .contextMenu { libraryContextMenu(for: rec) }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .navigationTitle(listTitle)
        }
    }

    // MARK: - Device Content

    @ViewBuilder
    private var deviceContent: some View {
        if let device = state.device.model {
            if device.files.isEmpty {
                ContentUnavailableView {
                    Label("No Files on Device", systemImage: "tray")
                } description: {
                    Text("Your HiDock \(device.model.rawValue) has no recordings.")
                }
            } else {
                List(selection: $state.device.selectedDeviceFiles) {
                    ForEach(filteredDeviceFiles(device.files)) { file in
                        DeviceFileRow(
                            file: file,
                            isDownloaded: state.library.isDownloaded(file.filename),
                            isDownloading: state.device.downloadingFiles.contains(file.filename),
                            isDeleting: state.device.deletingFiles.contains(file.filename)
                        )
                        .tag(file.filename)
                        .contextMenu {
                            Button { Task { await state.downloadFile(file) } } label: {
                                Label("Download", systemImage: "arrow.down.circle")
                            }
                            Divider()
                            Button(role: .destructive) { Task { await state.deleteFromDevice(file) } } label: {
                                Label("Delete from Device", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .navigationTitle("HiDock \(device.model.rawValue)")
            }
        }
    }

    // MARK: - Filtering & Sorting

    private var listTitle: String {
        switch state.selectedView {
        case .allRecordings: return "All Recordings"
        case .folder(let name): return name
        case .device: return "Device"
        }
    }

    private var filteredRecordings: [RecordingMetadata] {
        var recs = state.library.filteredByFolder

        if !filterMode.isEmpty {
            recs = recs.filter { $0.mode == filterMode }
        }
        if let startDate = filterPeriod.startDate {
            recs = recs.filter { ($0.recordedAt ?? .distantPast) >= startDate }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            recs = recs.filter {
                $0.filename.lowercased().contains(query) ||
                $0.displayTitle.lowercased().contains(query)
            }
        }

        switch sortBy {
        case .dateNewest: recs.sort { ($0.recordedAt ?? .distantPast) > ($1.recordedAt ?? .distantPast) }
        case .dateOldest: recs.sort { ($0.recordedAt ?? .distantPast) < ($1.recordedAt ?? .distantPast) }
        case .longest: recs.sort { $0.estimatedDuration > $1.estimatedDuration }
        case .shortest: recs.sort { $0.estimatedDuration < $1.estimatedDuration }
        }
        return recs
    }

    private func filteredDeviceFiles(_ files: [FileEntry]) -> [FileEntry] {
        let parsed = Dictionary(uniqueKeysWithValues: files.map {
            ($0.filename, FilenameParsing.parse($0.filename))
        })
        var result = files
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { $0.filename.lowercased().contains(query) }
        }
        result.sort { (parsed[$0.filename]?.date ?? .distantPast) > (parsed[$1.filename]?.date ?? .distantPast) }
        return result
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func libraryContextMenu(for rec: RecordingMetadata) -> some View {
        let isPlaying = state.playback.playingFile == rec.filename && state.playback.isPlaying
        Button { state.playRecording(rec) } label: {
            Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
        }
        Divider()
        let status = state.transcription.statuses[rec.filename] ?? .none
        if state.transcription.transcribingFile == rec.filename {
            Button { state.transcription.cancel() } label: {
                Label("Cancel Transcription", systemImage: "xmark.circle")
            }
        } else {
            Button { Task { await state.transcribeRecordings([rec]) } } label: {
                Label(status == .done ? "Re-transcribe" : "Transcribe", systemImage: "text.badge.plus")
            }
        }
        Divider()
        Button { state.library.revealInFinder(rec) } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        Divider()
        Button(role: .destructive) { Task { await state.deleteLocalRecording(rec) } } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

// MARK: - Library Row (reused from current codebase, adapted)

private struct LibraryRow: View {
    let recording: RecordingMetadata
    let transcriptStatus: TranscriptStatus
    let isTranscribing: Bool
    let isCurrentlyPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(modeColor.opacity(0.15)).frame(width: 36, height: 36)
                Image(systemName: modeIcon).foregroundStyle(modeColor).font(.system(size: 14))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(recording.displayTitle).font(.body.weight(.medium))
                HStack(spacing: 8) {
                    Text(modeLabel)
                        .font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(modeColor.opacity(0.1)).foregroundStyle(modeColor).clipShape(Capsule())
                    Label(formattedDuration, systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                    if let folder = recording.folder {
                        Label(folder, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            HStack(spacing: 8) {
                if isCurrentlyPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption).foregroundStyle(Color.accentColor)
                        .symbolEffect(.variableColor.iterative, isActive: true)
                }
                if isTranscribing { ProgressView().controlSize(.small) }
                transcriptBadge
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var transcriptBadge: some View {
        switch transcriptStatus {
        case .done: Image(systemName: "text.badge.checkmark").font(.caption).foregroundStyle(.green).help("Transcribed")
        case .inProgress: Image(systemName: "text.badge.plus").font(.caption).foregroundStyle(.orange)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).help("Transcription failed")
        case .none: EmptyView()
        }
    }

    private var modeLabel: String { FilenameParsing.RecordingMode(rawValue: recording.mode)?.displayName ?? recording.mode }
    private var modeIcon: String {
        switch recording.mode {
        case "Rec": "mic.fill"; case "Pho": "phone.fill"; case "Mee": "person.3.fill"; case "Wip": "pencil.line"; default: "waveform"
        }
    }
    private var modeColor: Color {
        switch recording.mode {
        case "Rec": .blue; case "Pho": .green; case "Mee": .purple; case "Wip": .orange; default: .secondary
        }
    }
    private var formattedDuration: String { DurationCalculator.formatDuration(recording.estimatedDuration) }
}

// MARK: - Device File Row (reused from current codebase)

private struct DeviceFileRow: View {
    let file: FileEntry
    let isDownloaded: Bool
    let isDownloading: Bool
    let isDeleting: Bool
    private let parsed: FilenameParsing.ParsedFilename

    init(file: FileEntry, isDownloaded: Bool, isDownloading: Bool, isDeleting: Bool) {
        self.file = file; self.isDownloaded = isDownloaded
        self.isDownloading = isDownloading; self.isDeleting = isDeleting
        self.parsed = FilenameParsing.parse(file.filename)
    }

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter(); fmt.dateStyle = .medium; fmt.timeStyle = .short; return fmt
    }()

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(modeColor.opacity(0.15)).frame(width: 36, height: 36)
                Image(systemName: modeIcon).foregroundStyle(modeColor).font(.system(size: 14))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName).font(.body.weight(.medium))
                HStack(spacing: 8) {
                    Text(parsed.mode.displayName)
                        .font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(modeColor.opacity(0.1)).foregroundStyle(modeColor).clipShape(Capsule())
                    Label(formattedDuration, systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                    Label(formattedSize, systemImage: "doc").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                if isDownloading { ProgressView().controlSize(.small).accessibilityLabel("Downloading") }
                if isDeleting { ProgressView().controlSize(.small).accessibilityLabel("Deleting") }
                if isDownloaded {
                    Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                        .accessibilityLabel("Already downloaded").help("Already downloaded")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var displayName: String {
        if let date = parsed.date { return Self.dateFormatter.string(from: date) }
        return file.filename
    }
    private var modeIcon: String {
        switch parsed.mode {
        case .standard: "mic.fill"; case .phone: "phone.fill"; case .meeting: "person.3.fill"; case .wip: "pencil.line"; case .unknown: "waveform"
        }
    }
    private var modeColor: Color {
        switch parsed.mode {
        case .standard: .blue; case .phone: .green; case .meeting: .purple; case .wip: .orange; case .unknown: .secondary
        }
    }
    private var formattedSize: String { ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file) }
    private var formattedDuration: String { DurationCalculator.formatDuration(DurationCalculator.estimateDuration(fileSize: UInt64(file.size))) }
}
```

- [ ] **Step 2: Create DetailPane (Column 3)**

```swift
// Sources/DockTape/Views/DetailPane.swift
import SwiftUI
import HiDockKit

struct DetailPane: View {
    @Bindable var state: AppState
    @State private var selectedTab: DetailTab = .transcript
    @State private var transcript: Transcript?

    enum DetailTab: Hashable {
        case transcript
        case info
    }

    var body: some View {
        VStack(spacing: 0) {
            if let content = resolvedContent {
                content
            } else {
                ContentUnavailableView {
                    Label("No Selection", systemImage: "doc.text")
                } description: {
                    Text("Select a recording to view details.")
                }
            }
        }
    }

    @ViewBuilder
    private var resolvedContent: (some View)? {
        switch state.selectedView {
        case .allRecordings, .folder:
            if state.library.selectedRecordings.count > 1 {
                multiSelectView
            } else if let filename = state.library.selectedRecordings.first,
                      let rec = state.library.recordings.first(where: { $0.filename == filename }) {
                recordingDetail(rec)
            } else {
                nil
            }
        case .device:
            if let filename = state.device.selectedDeviceFiles.first,
               let file = state.device.files.first(where: { $0.filename == filename }) {
                deviceFileDetail(file)
            } else {
                nil
            }
        }
    }

    // MARK: - Recording Detail

    @ViewBuilder
    private func recordingDetail(_ rec: RecordingMetadata) -> some View {
        let hasTranscript = transcript != nil

        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rec.displayTitle).font(.headline)
                    Text(headerSubtitle(for: rec)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, hasTranscript ? 0 : 12)

            // Tab bar (only when multiple tabs)
            if hasTranscript {
                HStack(spacing: 0) {
                    tabButton("Transcript", tab: .transcript)
                    tabButton("Info", tab: .info)
                    Spacer()
                }
                .padding(.horizontal, 12)
                Divider()
            }

            // Tab content
            Group {
                if hasTranscript && selectedTab == .transcript {
                    transcriptContent(rec)
                } else {
                    InfoTabView(recording: rec, transcriptStatus: state.transcription.statuses[rec.filename] ?? .none)
                }
            }
            .frame(maxHeight: .infinity)

            // Transcription bar
            if state.transcription.transcribingFile == rec.filename {
                TranscriptionBar(transcription: state.transcription)
            }

            // Player bar
            PlayerBar(playback: state.playback)
        }
        .onChange(of: rec.filename, initial: true) { _, newFilename in
            Task { transcript = await state.library.transcript(for: newFilename) }
            selectedTab = .transcript
        }
        .onChange(of: state.transcription.statuses[rec.filename]) { _, status in
            if status == .done {
                Task { transcript = await state.library.transcript(for: rec.filename) }
            }
        }
    }

    @ViewBuilder
    private func transcriptContent(_ rec: RecordingMetadata) -> some View {
        if let transcript {
            TranscriptViewer(
                transcript: transcript,
                activeSegmentIndex: state.playback.activeSegmentIndex,
                onSeek: { time in
                    if state.playback.playingFile == rec.filename {
                        state.playback.seek(to: time)
                    } else {
                        let url = state.library.store.baseDirectory.appendingPathComponent(rec.filename)
                        state.playback.play(file: rec.filename, url: url)
                        state.playback.seek(to: time)
                    }
                },
                onSaveSpeakerNames: { names in
                    Task { await state.updateSpeakerNames(for: rec.filename, names: names) }
                    Task { self.transcript = await state.library.transcript(for: rec.filename) }
                }
            )
            .onAppear {
                state.playback.setSegmentTimestamps(transcript.segments.map(\.startTime))
            }
            .onChange(of: transcript.segments.count) {
                state.playback.setSegmentTimestamps(transcript.segments.map(\.startTime))
            }
        }
    }

    // MARK: - Device File Detail

    @ViewBuilder
    private func deviceFileDetail(_ file: FileEntry) -> some View {
        let parsed = FilenameParsing.parse(file.filename)
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.filename).font(.headline)
                    Text("On Device · Not yet downloaded").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            Divider()
            InfoTabView(deviceFile: file, parsed: parsed)
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Multi-select

    private var multiSelectView: some View {
        MultiSelectSummary(
            count: state.library.selectedRecordings.count,
            recordings: state.library.recordings.filter { state.library.selectedRecordings.contains($0.filename) }
        )
    }

    // MARK: - Tab Button

    private func tabButton(_ title: String, tab: DetailTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            Text(title)
                .font(.subheadline.weight(selectedTab == tab ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(selectedTab == tab ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if selectedTab == tab {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
    }

    private func headerSubtitle(for rec: RecordingMetadata) -> String {
        var parts: [String] = []
        if let date = rec.recordedAt {
            let fmt = DateFormatter(); fmt.dateStyle = .medium; fmt.timeStyle = .short
            parts.append(fmt.string(from: date))
        }
        parts.append(DurationCalculator.formatDuration(rec.estimatedDuration))
        if !rec.mode.isEmpty {
            parts.append(FilenameParsing.RecordingMode(rawValue: rec.mode)?.displayName ?? rec.mode)
        }
        if let folder = rec.folder { parts.append(folder) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Player Bar (extracted from ContentView)

struct PlayerBar: View {
    @Bindable var playback: PlaybackState
    @State private var isSeeking = false
    @State private var seekValue: Double = 0

    var body: some View {
        if playback.playingFile != nil {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 12) {
                    Button { playback.togglePlayPause() } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 20)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

                    Text(formatTime(isSeeking ? seekValue : playback.progress))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)

                    Slider(
                        value: Binding(
                            get: { isSeeking ? seekValue : playback.progress },
                            set: { seekValue = $0 }
                        ),
                        in: 0...max(playback.duration, 1)
                    ) { editing in
                        if editing { isSeeking = true }
                        else { playback.seek(to: seekValue); isSeeking = false }
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Playback position")

                    Text(formatTime(playback.duration))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)

                    Menu {
                        ForEach(PlaybackState.speeds, id: \.self) { speed in
                            Button { playback.setRate(speed) } label: {
                                HStack {
                                    Text(speedLabel(speed))
                                    if playback.rate == speed { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        Text(speedLabel(playback.rate))
                            .font(.caption.monospacedDigit().weight(.medium)).frame(minWidth: 30)
                    }
                    .menuStyle(.borderlessButton).fixedSize().help("Playback speed")

                    Button { playback.stop() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Stop playback")
                }
                .padding(.horizontal, 16).padding(.vertical, 8).background(.bar)
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds); let h = total / 3600; let m = (total % 3600) / 60; let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private func speedLabel(_ rate: Float) -> String {
        if rate == 1.0 { return "1x" }
        if rate == floor(rate) { return "\(Int(rate))x" }
        return String(format: "%.2gx", rate)
    }
}

// MARK: - Transcription Bar (extracted from ContentView)

struct TranscriptionBar: View {
    @Bindable var transcription: TranscriptionState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = transcription.startTime.map { context.date.timeIntervalSince($0) } ?? 0
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(transcription.phase).font(.caption.weight(.medium))
                            if transcription.queue.count > 1 {
                                Text("\(transcription.queueIndex + 1) of \(transcription.queue.count)")
                                    .font(.caption.monospacedDigit())
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(.orange.opacity(0.15)).clipShape(Capsule())
                            }
                        }
                    }
                    Spacer()
                    Text(formatElapsed(elapsed)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button { transcription.cancel() } label: {
                        Label("Cancel", systemImage: "xmark.circle.fill").font(.caption)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal, 16).padding(.vertical, 8).background(.orange.opacity(0.08))
            }
        }
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds); return String(format: "%d:%02d", total / 60, total % 60)
    }
}
```

- [ ] **Step 3: Create InfoTabView**

```swift
// Sources/DockTape/Views/InfoTabView.swift
import SwiftUI
import HiDockKit

struct InfoTabView: View {
    // For library recordings
    var recording: RecordingMetadata? = nil
    var transcriptStatus: TranscriptStatus = .none

    // For device files
    var deviceFile: FileEntry? = nil
    var parsed: FilenameParsing.ParsedFilename? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let rec = recording {
                    recordingInfo(rec)
                } else if let file = deviceFile, let parsed {
                    deviceFileInfo(file, parsed: parsed)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func recordingInfo(_ rec: RecordingMetadata) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            infoRow("Filename", rec.filename)
            infoRow("Duration", DurationCalculator.formatDuration(rec.estimatedDuration))
            infoRow("Size", ByteCountFormatter.string(fromByteCount: Int64(rec.fileSizeBytes), countStyle: .file))
            if !rec.mode.isEmpty {
                infoRow("Mode", FilenameParsing.RecordingMode(rawValue: rec.mode)?.displayName ?? rec.mode)
            }
            if let date = rec.recordedAt {
                let fmt = DateFormatter()
                let _ = (fmt.dateStyle = .long, fmt.timeStyle = .medium)
                infoRow("Recorded", fmt.string(from: date))
            }
            if let folder = rec.folder {
                infoRow("Folder", folder)
            }
            infoRow("Transcript", transcriptLabel)
        }
    }

    @ViewBuilder
    private func deviceFileInfo(_ file: FileEntry, parsed: FilenameParsing.ParsedFilename) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            infoRow("Filename", file.filename)
            infoRow("Size", ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
            infoRow("Est. Duration", DurationCalculator.formatDuration(DurationCalculator.estimateDuration(fileSize: UInt64(file.size))))
            infoRow("Mode", parsed.mode.displayName)
            if let date = parsed.date {
                let fmt = DateFormatter()
                let _ = (fmt.dateStyle = .long, fmt.timeStyle = .medium)
                infoRow("Date", fmt.string(from: date))
            }
            GridRow {
                Text("Status").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                    Text("On device").font(.body).foregroundStyle(.orange)
                }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some GridRow<some View> {
        GridRow {
            Text(label).font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).font(.body).textSelection(.enabled)
        }
    }

    private var transcriptLabel: String {
        switch transcriptStatus {
        case .done: "Available"
        case .inProgress: "In progress..."
        case .failed: "Failed"
        case .none: "None"
        }
    }
}
```

- [ ] **Step 4: Create MultiSelectSummary**

```swift
// Sources/DockTape/Views/MultiSelectSummary.swift
import SwiftUI
import HiDockKit

struct MultiSelectSummary: View {
    let count: Int
    let recordings: [RecordingMetadata]

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("\(count) Items Selected")
                .font(.headline)

            HStack(spacing: 16) {
                Label(totalDuration, systemImage: "clock")
                Label(totalSize, systemImage: "doc")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Divider().frame(width: 200)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(recordings) { rec in
                        HStack {
                            Text(rec.displayTitle)
                                .font(.caption)
                            Spacer()
                            Text(DurationCalculator.formatDuration(rec.estimatedDuration))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .frame(maxHeight: 200)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var totalDuration: String {
        let total = recordings.reduce(0.0) { $0 + $1.estimatedDuration }
        return DurationCalculator.formatDuration(total)
    }

    private var totalSize: String {
        let total = recordings.reduce(UInt64(0)) { $0 + $1.fileSizeBytes }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }
}
```

- [ ] **Step 5: Build**

Run: `xcodebuild build -scheme DockTape 2>&1 | tail -10`
Expected: May still have errors from ContentView and DockTapeApp referencing old API. We fix those next.

- [ ] **Step 6: Commit**

```bash
git add Sources/DockTape/Views/RecordingListPane.swift Sources/DockTape/Views/DetailPane.swift Sources/DockTape/Views/InfoTabView.swift Sources/DockTape/Views/MultiSelectSummary.swift
git commit -m "feat: RecordingListPane, DetailPane with progressive tabs, InfoTab, MultiSelectSummary"
```

---

## Task 9: ContentView — 3-Column Layout + TranscriptViewer Update

Rewrite ContentView for the 3-column layout and update TranscriptViewer to support live highlighting.

**Files:**
- Modify: `Sources/DockTape/Views/ContentView.swift`
- Modify: `Sources/DockTape/Views/TranscriptViewer.swift`

- [ ] **Step 1: Rewrite ContentView**

Replace the entire contents of `ContentView.swift`:

```swift
// Sources/DockTape/Views/ContentView.swift
import SwiftUI
import HiDockKit

struct ContentView: View {
    @Bindable var state: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView(state: state)
        } content: {
            RecordingListPane(state: state)
                .toolbar { toolbarContent }
        } detail: {
            DetailPane(state: state)
        }
        .navigationTitle("")
        .frame(minWidth: 900, minHeight: 550)
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

    // MARK: - Toolbar (contextual based on sidebar selection)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            switch state.selectedView {
            case .allRecordings, .folder:
                libraryToolbar
            case .device:
                deviceToolbar
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            sortAndFilterMenus
        }
    }

    @ViewBuilder
    private var libraryToolbar: some View {
        let singleRec = singleSelectedRecording
        let hasSelection = !state.library.selectedRecordings.isEmpty

        Button {
            if let rec = singleRec { state.playRecording(rec) }
        } label: {
            let playing = singleRec.map { state.playback.playingFile == $0.filename && state.playback.isPlaying } ?? false
            Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill")
        }
        .disabled(singleRec == nil)

        Button {
            let toTranscribe = selectedRecordings.filter {
                (state.transcription.statuses[$0.filename] ?? .none) != .done
            }
            if !toTranscribe.isEmpty {
                Task { await state.transcribeRecordings(toTranscribe) }
            }
        } label: {
            Label("Transcribe", systemImage: "text.word.spacing")
        }
        .disabled(!hasSelection)

        Button {
            // Export — TODO: implement export sheet
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(singleRec == nil)

        Button(role: .destructive) {
            Task {
                for rec in selectedRecordings { await state.deleteLocalRecording(rec) }
                state.library.selectedRecordings.removeAll()
            }
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(!hasSelection)
    }

    @ViewBuilder
    private var deviceToolbar: some View {
        let selectedFiles = state.device.files.filter { state.device.selectedDeviceFiles.contains($0.filename) }
        let hasSelection = !selectedFiles.isEmpty

        Button {
            Task {
                for file in selectedFiles { await state.downloadFile(file) }
            }
        } label: {
            Label("Download", systemImage: "arrow.down.circle")
        }
        .disabled(!hasSelection || state.device.isSyncing)

        Button(role: .destructive) {
            Task {
                for file in selectedFiles { await state.deleteFromDevice(file) }
                state.device.selectedDeviceFiles.removeAll()
            }
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(!hasSelection)

        Button {
            Task { await state.device.refreshDevice() }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r", modifiers: .command)
    }

    @ViewBuilder
    private var sortAndFilterMenus: some View {
        // Placeholder — sort/filter menus are handled by RecordingListPane's @AppStorage
        // These will be wired up as needed
        EmptyView()
    }

    // MARK: - Helpers

    private var singleSelectedRecording: RecordingMetadata? {
        guard state.library.selectedRecordings.count == 1,
              let filename = state.library.selectedRecordings.first else { return nil }
        return state.library.recordings.first { $0.filename == filename }
    }

    private var selectedRecordings: [RecordingMetadata] {
        state.library.recordings.filter { state.library.selectedRecordings.contains($0.filename) }
    }
}

// MARK: - Search Focus Modifier

struct SearchFocusModifier: ViewModifier {
    @Binding var trigger: Bool
    @FocusState private var isSearchFocused: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .searchFocused($isSearchFocused)
                .onChange(of: trigger) { _, focused in
                    if focused { isSearchFocused = true; trigger = false }
                }
        } else {
            content
        }
    }
}
```

- [ ] **Step 2: Update TranscriptViewer for live highlighting**

Update `TranscriptViewer.swift` to accept `activeSegmentIndex` and highlight/scroll:

In the struct declaration, add the parameter:
```swift
struct TranscriptViewer: View {
    let transcript: Transcript
    var activeSegmentIndex: Int? = nil
    var onSeek: ((TimeInterval) -> Void)?
    var onSaveSpeakerNames: (([String: String]) -> Void)?
```

Remove the `@Environment(\.dismiss) private var dismiss` line and the `frame(minWidth:minHeight:)` / `frame(idealWidth:idealHeight:)` modifiers (it's no longer a sheet).

Replace the ScrollView section with a `ScrollViewReader`:
```swift
            // Transcript content
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(filteredSegments.enumerated()), id: \.element.id) { index, segment in
                            let isActive = activeSegmentIndex == segmentIndexInFull(segment)
                            SegmentRow(
                                segment: segment,
                                speakerNames: speakerNames,
                                isActive: isActive,
                                onSeek: onSeek,
                                onTapSpeaker: { sid in
                                    editingSpeaker = sid
                                    editText = speakerNames[sid] ?? sid
                                }
                            )
                            .id(segment.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: activeSegmentIndex) { _, newIndex in
                    if let newIndex, newIndex < transcript.segments.count {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(transcript.segments[newIndex].id, anchor: .center)
                        }
                    }
                }
            }
```

Add the helper method:
```swift
    private func segmentIndexInFull(_ segment: Transcript.Segment) -> Int {
        transcript.segments.firstIndex(where: { $0.id == segment.id }) ?? 0
    }
```

Remove the `saveAndDismiss()` method and the "Done" button — it's no longer a sheet. Remove `onExitCommand` handler.

Update `SegmentRow` to accept `isActive`:
```swift
private struct SegmentRow: View {
    let segment: Transcript.Segment
    let speakerNames: [String: String]
    var isActive: Bool = false
    var onSeek: ((TimeInterval) -> Void)?
    var onTapSpeaker: ((String) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Leading accent bar for active segment
            RoundedRectangle(cornerRadius: 2)
                .fill(isActive ? Color.accentColor : Color.clear)
                .frame(width: 3)

            // ... rest of row unchanged
```

- [ ] **Step 3: Build**

Run: `xcodebuild build -scheme DockTape 2>&1 | tail -20`
Expected: Build may have residual errors from SettingsView, DeviceInfoView, or MenuBarView referencing old AppState properties. These are addressed next.

- [ ] **Step 4: Commit**

```bash
git add Sources/DockTape/Views/ContentView.swift Sources/DockTape/Views/TranscriptViewer.swift
git commit -m "feat: 3-column ContentView, TranscriptViewer with live highlight and scroll-to-active"
```

---

## Task 10: DockTapeApp — Menu Bar Rewrite + Fix Remaining Views

Rewrite `AppCommands` for the new menu structure and fix any remaining views that reference the old `AppState` API.

**Files:**
- Modify: `Sources/DockTape/DockTapeApp.swift`
- Modify: `Sources/DockTape/Views/SettingsView.swift`
- Modify: `Sources/DockTape/Views/MenuBarView.swift`
- Modify: `Sources/DockTape/Views/DeviceInfoView.swift`
- Delete: `Sources/DockTape/Views/RecordingListView.swift`
- Delete: `Sources/DockTape/Views/DeviceFilesView.swift`
- Delete: `Sources/DockTape/Views/DownloadProgressView.swift`
- Delete: `Sources/DockTape/Views/EmptyStateView.swift`

- [ ] **Step 1: Rewrite AppCommands in DockTapeApp.swift**

Replace the `AppCommands` struct:

```swift
struct AppCommands: Commands {
    @FocusedValue(\.appState) var state

    var body: some Commands {
        // File menu
        CommandGroup(replacing: .newItem) {
            Button("New Folder") {
                // Trigger folder creation via state
            }
            .keyboardShortcut("n", modifiers: .command)

            Divider()

            Button("Export...") {}
            .keyboardShortcut("e", modifiers: .command)
            .disabled(state?.library.selectedRecordings.isEmpty != false)

            Divider()

            Button("Delete") {
                guard let state else { return }
                Task {
                    for filename in state.library.selectedRecordings {
                        if let rec = state.library.recordings.first(where: { $0.filename == filename }) {
                            await state.deleteLocalRecording(rec)
                        }
                    }
                    state.library.selectedRecordings.removeAll()
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(state?.library.selectedRecordings.isEmpty != false)
        }

        // Edit menu — search
        CommandGroup(replacing: .textEditing) {
            Button("Find") { state?.library.isSearchFocused = true }
            .keyboardShortcut("f", modifiers: .command)
            Divider()
        }

        // View menu
        CommandGroup(after: .sidebar) {
            Button("Show Library") { state?.selectedView = .allRecordings }
            .keyboardShortcut("1", modifiers: .command)

            Button("Show Device") {
                guard state?.device.isConnected == true else { return }
                state?.selectedView = .device
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(state?.device.isConnected != true)

            Divider()

            Button("Device Info") { state?.device.showDeviceInfo = true }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(state?.device.isConnected != true)

            Divider()
        }

        // Recording menu
        CommandMenu("Recording") {
            Button(state?.playback.isPlaying == true ? "Pause" : "Play") {
                state?.playback.togglePlayPause()
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(state?.playback.playingFile == nil)

            Button("Stop") { state?.playback.stop() }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(state?.playback.playingFile == nil)

            Divider()

            Button("Transcribe") {
                guard let state else { return }
                let recs = state.library.recordings.filter { state.library.selectedRecordings.contains($0.filename) }
                Task { await state.transcribeRecordings(recs) }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(state?.library.selectedRecordings.isEmpty != false)

            Divider()

            Button("Increase Speed") {
                guard let state else { return }
                let speeds = PlaybackState.speeds
                if let idx = speeds.firstIndex(of: state.playback.rate), idx + 1 < speeds.count {
                    state.playback.setRate(speeds[idx + 1])
                }
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(state?.playback.playingFile == nil)

            Button("Decrease Speed") {
                guard let state else { return }
                let speeds = PlaybackState.speeds
                if let idx = speeds.firstIndex(of: state.playback.rate), idx > 0 {
                    state.playback.setRate(speeds[idx - 1])
                }
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(state?.playback.playingFile == nil)

            Button("Reset Speed") { state?.playback.setRate(1.0) }
            .keyboardShortcut("\\", modifiers: .command)
            .disabled(state?.playback.playingFile == nil)

            Divider()

            Menu("Move to") {
                Button("Root") {
                    guard let state else { return }
                    Task {
                        for filename in state.library.selectedRecordings {
                            try? await state.library.moveRecording(filename: filename, toFolder: nil)
                        }
                    }
                }
                Divider()
                ForEach(state?.library.folders ?? [], id: \.self) { folder in
                    Button(folder) {
                        guard let state else { return }
                        Task {
                            for filename in state.library.selectedRecordings {
                                try? await state.library.moveRecording(filename: filename, toFolder: folder)
                            }
                        }
                    }
                }
            }
            .disabled(state?.library.selectedRecordings.isEmpty != false)
        }

        // Device menu
        CommandMenu("Device") {
            Button("Refresh Files") { Task { await state?.device.refreshDevice() } }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(state?.device.isConnected != true)

            Button("Sync All") { Task { await state?.syncAll() } }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(state?.device.isConnected != true)

            Button("Device Info") { state?.device.showDeviceInfo = true }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(state?.device.isConnected != true)
        }
    }
}
```

- [ ] **Step 2: Fix SettingsView, MenuBarView, DeviceInfoView**

These views reference `state.device`, `state.isConnected`, etc. — update them to use the new sub-object paths. Key changes:

- `state.isConnected` → `state.device.isConnected`
- `state.device` (was `DeviceModel?`) → `state.device.model`
- `state.showDeviceInfo` → `state.device.showDeviceInfo`
- `state.isSyncing` → `state.device.isSyncing`
- `state.isFormattingCard` → `state.device.isFormattingCard`
- `state.recordings` → `state.library.recordings`

Read each file, find old references, and update. The compiler errors will guide you.

- [ ] **Step 3: Delete replaced view files**

```bash
rm Sources/DockTape/Views/RecordingListView.swift
rm Sources/DockTape/Views/DeviceFilesView.swift
rm Sources/DockTape/Views/DownloadProgressView.swift
rm Sources/DockTape/Views/EmptyStateView.swift
```

- [ ] **Step 4: Build successfully**

Run: `xcodebuild build -scheme DockTape 2>&1 | tail -10`
Expected: **BUILD SUCCEEDED**. If there are errors, fix them — this is where all the wiring comes together.

- [ ] **Step 5: Run tests**

Run: `xcodebuild test -scheme HiDockKitTests 2>&1 | grep -E '(Test Suite|Executed|FAIL)'`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: complete 3-pane redesign — menu bar, view wiring, remove replaced files

3-column NavigationSplitView with real filesystem folders,
progressive tabs, contextual toolbar, Recording/Device menus,
and AppState split into 4 sub-objects."
```

---

## Task 11: Speaker Split/Merge Context Menus

Add speaker split and merge context menus to transcript segments.

**Files:**
- Modify: `Sources/DockTape/Views/TranscriptViewer.swift`
- Modify: `Sources/HiDockKit/Transcription/TranscriptStore.swift`

- [ ] **Step 1: Add `splitSpeaker` method to TranscriptStore**

```swift
    /// Split a speaker at a specific segment: assign a new speaker ID to this segment
    /// and optionally all following segments by the same speaker.
    public func splitSpeaker(
        for mp3Filename: String,
        segmentID: UUID,
        allFollowing: Bool
    ) throws {
        guard var transcript = cache[mp3Filename] else { return }
        guard let segIndex = transcript.segments.firstIndex(where: { $0.id == segmentID }),
              let originalSID = transcript.segments[segIndex].speakerID else { return }

        // Generate new speaker ID
        let existingCount = transcript.speakerIDs.count
        let newSID = "Speaker \(existingCount + 1)"

        if allFollowing {
            // Reassign this and all later segments with the same original speaker
            for i in segIndex..<transcript.segments.count {
                if transcript.segments[i].speakerID == originalSID {
                    transcript.segments[i] = Transcript.Segment(
                        id: transcript.segments[i].id,
                        startTime: transcript.segments[i].startTime,
                        endTime: transcript.segments[i].endTime,
                        text: transcript.segments[i].text,
                        speakerID: newSID,
                        confidence: transcript.segments[i].confidence
                    )
                }
            }
        } else {
            transcript.segments[segIndex] = Transcript.Segment(
                id: transcript.segments[segIndex].id,
                startTime: transcript.segments[segIndex].startTime,
                endTime: transcript.segments[segIndex].endTime,
                text: transcript.segments[segIndex].text,
                speakerID: newSID,
                confidence: transcript.segments[segIndex].confidence
            )
        }

        // Copy speaker name for new ID
        transcript.speakerNames[newSID] = newSID

        try save(transcript, mp3Filename: mp3Filename)
        markTxtDirty(mp3Filename)
    }
```

- [ ] **Step 2: Add context menus to SegmentRow in TranscriptViewer**

Add to `SegmentRow`'s body, wrapping the existing HStack:

```swift
    var onSplitSpeaker: ((UUID, Bool) -> Void)?
    var onMergeSpeaker: ((String, String) -> Void)?
    var allSpeakerIDs: [String] = []

    // In body, add .contextMenu to the outermost container:
    .contextMenu {
        if let sid = segment.speakerID {
            Button("Assign Different Speaker (this segment)") {
                onSplitSpeaker?(segment.id, false)
            }
            Button("Assign Different Speaker (this & following)") {
                onSplitSpeaker?(segment.id, true)
            }

            if allSpeakerIDs.count > 1 {
                Divider()
                Menu("Merge '\(speakerNames[sid] ?? sid)' with...") {
                    ForEach(allSpeakerIDs.filter { $0 != sid }, id: \.self) { otherSID in
                        Button(speakerNames[otherSID] ?? otherSID) {
                            onMergeSpeaker?(sid, otherSID)
                        }
                    }
                }
            }
        }
    }
```

- [ ] **Step 3: Wire up in TranscriptViewer's ForEach**

Update the `SegmentRow` instantiation to pass the new callbacks:

```swift
SegmentRow(
    segment: segment,
    speakerNames: speakerNames,
    isActive: isActive,
    onSeek: onSeek,
    onTapSpeaker: { sid in editingSpeaker = sid; editText = speakerNames[sid] ?? sid },
    onSplitSpeaker: { segID, allFollowing in
        Task {
            try? await state.library.transcriptStore.splitSpeaker(
                for: transcript.recordingFilename, segmentID: segID, allFollowing: allFollowing)
            // Reload transcript
            onSaveSpeakerNames?(speakerNames)
        }
    },
    onMergeSpeaker: { sourceSID, targetSID in
        Task {
            try? await state.library.transcriptStore.mergeSpeakers(
                for: transcript.recordingFilename, source: sourceSID, into: targetSID)
            onSaveSpeakerNames?(speakerNames)
        }
    },
    allSpeakerIDs: transcript.speakerIDs
)
```

Note: The TranscriptViewer doesn't have direct access to `state`. The split/merge callbacks will need to be threaded through as closures from DetailPane. Adjust the TranscriptViewer's init to accept `onSplitSpeaker` and `onMergeSpeaker` closures, and pass them through.

- [ ] **Step 4: Build and test**

Run: `xcodebuild build -scheme DockTape 2>&1 | tail -10`
Expected: BUILD SUCCEEDED.

Run: `xcodebuild test -scheme HiDockKitTests 2>&1 | grep -E '(Executed|FAIL)'`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/DockTape/Views/TranscriptViewer.swift Sources/HiDockKit/Transcription/TranscriptStore.swift
git commit -m "feat: speaker split/merge context menus on transcript segments"
```

---

## Task 12: Final Integration — Build, Test, Polish

Final build verification, test run, and any remaining compilation fixes.

- [ ] **Step 1: Full build**

Run: `xcodebuild build -scheme DockTape 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

- [ ] **Step 2: Full test suite**

Run: `xcodebuild test -scheme HiDockKitTests 2>&1 | grep -E '(Test Suite|Executed|FAIL)'`
Expected: All tests pass with 0 failures.

- [ ] **Step 3: Fix any remaining issues**

If build or test failures exist, fix them. Common issues at this stage:
- Missing imports
- Type mismatches from the AppState refactor
- Views referencing deleted files

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "chore: final integration fixes for 3-pane redesign"
```
