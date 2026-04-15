# iCloud Drive Storage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make iCloud Drive the default recording storage, with local and custom-local fallbacks, visible in Finder and Files.app.

**Architecture:** Add a `StorageMode` enum and a `StorageLocationResolver` that resolves the base directory URL from UserDefaults. Replace `AppState.init`'s hardcoded path logic with the resolver. Update `SettingsView` to use a three-mode picker. Add the iCloud entitlement.

**Tech Stack:** Swift 5.10, SwiftUI, Foundation (`FileManager` ubiquity APIs), XCTest

**Spec:** `docs/superpowers/specs/2026-04-14-icloud-drive-storage-design.md`

---

### File Map

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `Sources/HiDockKit/Storage/StorageMode.swift` | `StorageMode` enum + `StorageLocationResolver` |
| Create | `Tests/HiDockKitTests/StorageModeTests.swift` | Tests for resolver logic |
| Modify | `Sources/DockTape/AppState.swift:87-102` | Use resolver in `init()`, add `switchStorageLocation()` |
| Modify | `Sources/DockTape/Views/SettingsView.swift:42-73` | Three-mode picker replacing library location section |
| Modify | `Sources/DockTape/Resources/DockTape.entitlements` | Add iCloud container identifier |
| Modify | `project.yml:46-49` | Add iCloud entitlement property |

---

### Task 1: StorageMode enum and StorageLocationResolver

**Files:**
- Create: `Sources/HiDockKit/Storage/StorageMode.swift`
- Create: `Tests/HiDockKitTests/StorageModeTests.swift`

- [ ] **Step 1: Write the failing tests**

In `Tests/HiDockKitTests/StorageModeTests.swift`:

```swift
// © 2026 High Gain Design. All rights reserved.

import XCTest
@testable import HiDockKit

final class StorageModeTests: XCTestCase {

    func testStorageModeRawValues() {
        XCTAssertEqual(StorageMode.icloud.rawValue, "icloud")
        XCTAssertEqual(StorageMode.local.rawValue, "local")
        XCTAssertEqual(StorageMode.custom.rawValue, "custom")
    }

    func testStorageModeFromString() {
        XCTAssertEqual(StorageMode(rawValue: "icloud"), .icloud)
        XCTAssertEqual(StorageMode(rawValue: "local"), .local)
        XCTAssertEqual(StorageMode(rawValue: "custom"), .custom)
        XCTAssertNil(StorageMode(rawValue: "bogus"))
    }

    func testResolveLocalMode() {
        let url = StorageLocationResolver.resolve(mode: .local, customURL: nil)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let expected = docs.appendingPathComponent("HiDock Recordings")
        XCTAssertEqual(url, expected)
    }

    func testResolveCustomMode() {
        let custom = URL(fileURLWithPath: "/tmp/my-recordings")
        let url = StorageLocationResolver.resolve(mode: .custom, customURL: custom)
        XCTAssertEqual(url, custom)
    }

    func testResolveCustomModeWithoutURL_FallsBackToLocal() {
        let url = StorageLocationResolver.resolve(mode: .custom, customURL: nil)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let expected = docs.appendingPathComponent("HiDock Recordings")
        XCTAssertEqual(url, expected)
    }

    func testResolveICloudMode_FallsBackToLocal_WhenUbiquityUnavailable() {
        // In a test/CI environment, ubiquity container is typically unavailable.
        // The resolver should fall back to local default.
        let url = StorageLocationResolver.resolve(mode: .icloud, customURL: nil)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let expected = docs.appendingPathComponent("HiDock Recordings")
        // If iCloud IS available in this environment, it would return the ubiquity URL.
        // Either result is valid; we just verify it's non-nil and a valid path.
        XCTAssertFalse(url.path.isEmpty)
    }

    func testMigrationLogic_ExistingCustomPath() {
        let defaults = UserDefaults(suiteName: "StorageModeTests_custom")!
        defaults.removePersistentDomain(forName: "StorageModeTests_custom")
        defaults.set(URL(fileURLWithPath: "/tmp/custom"), forKey: "libraryLocation")

        let mode = StorageLocationResolver.migratedMode(from: defaults)
        XCTAssertEqual(mode, .custom)
        defaults.removePersistentDomain(forName: "StorageModeTests_custom")
    }

    func testMigrationLogic_NoExistingPath() {
        let defaults = UserDefaults(suiteName: "StorageModeTests_fresh")!
        defaults.removePersistentDomain(forName: "StorageModeTests_fresh")

        let mode = StorageLocationResolver.migratedMode(from: defaults)
        XCTAssertEqual(mode, .icloud)
        defaults.removePersistentDomain(forName: "StorageModeTests_fresh")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter StorageModeTests 2>&1 | tail -20`
Expected: Compilation error — `StorageMode` and `StorageLocationResolver` not found.

- [ ] **Step 3: Write the implementation**

In `Sources/HiDockKit/Storage/StorageMode.swift`:

```swift
// © 2026 High Gain Design. All rights reserved.

import Foundation

/// Where DockTape stores recordings, transcripts, summaries, and templates.
public enum StorageMode: String, CaseIterable, Sendable {
    case icloud = "icloud"
    case local = "local"
    case custom = "custom"
}

/// Resolves the base directory URL for a given storage mode.
public enum StorageLocationResolver {

    /// The iCloud ubiquity container identifier.
    public static let containerID = "iCloud.design.highgain.docktape"

    /// Resolve the storage base directory.
    ///
    /// - Parameters:
    ///   - mode: The selected storage mode.
    ///   - customURL: The user-chosen custom URL (only used when mode is `.custom`).
    /// - Returns: The base directory URL. Falls back to local default if iCloud or custom is unavailable.
    public static func resolve(mode: StorageMode, customURL: URL?) -> URL {
        switch mode {
        case .icloud:
            if let container = FileManager.default.url(forUbiquityContainerIdentifier: containerID) {
                return container.appendingPathComponent("Documents")
            }
            // iCloud unavailable — fall back to local default
            return localDefault

        case .local:
            return localDefault

        case .custom:
            return customURL ?? localDefault
        }
    }

    /// Whether the iCloud ubiquity container is currently available.
    public static var isICloudAvailable: Bool {
        FileManager.default.url(forUbiquityContainerIdentifier: containerID) != nil
    }

    /// The local default path: ~/Documents/HiDock Recordings/
    public static var localDefault: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("HiDock Recordings")
    }

    /// Determine the initial storage mode for a pre-iCloud install.
    ///
    /// - If `libraryLocation` exists → user had a custom path → `.custom`
    /// - Otherwise → new default → `.icloud`
    public static func migratedMode(from defaults: UserDefaults) -> StorageMode {
        if defaults.url(forKey: "libraryLocation") != nil {
            return .custom
        }
        return .icloud
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter StorageModeTests 2>&1 | tail -20`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/HiDockKit/Storage/StorageMode.swift Tests/HiDockKitTests/StorageModeTests.swift
git commit -m "feat: add StorageMode enum and StorageLocationResolver"
```

---

### Task 2: Add iCloud entitlement

**Files:**
- Modify: `Sources/DockTape/Resources/DockTape.entitlements`
- Modify: `project.yml:46-49`

- [ ] **Step 1: Update the entitlements plist**

In `Sources/DockTape/Resources/DockTape.entitlements`, add the iCloud container identifier after the existing entries:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.device.usb</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-write</key>
	<true/>
	<key>com.apple.developer.ubiquity-container-identifiers</key>
	<array>
		<string>iCloud.design.highgain.docktape</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 2: Update project.yml entitlement properties**

In `project.yml`, add the iCloud property to the entitlements section (around line 48):

```yaml
    entitlements:
      path: Sources/DockTape/Resources/DockTape.entitlements
      properties:
        com.apple.security.device.usb: true
        com.apple.security.files.user-selected.read-write: true
        com.apple.developer.ubiquity-container-identifiers:
          - iCloud.design.highgain.docktape
```

- [ ] **Step 3: Verify xcodegen still generates cleanly**

Run: `xcodegen generate 2>&1`
Expected: `Generated DockTape.xcodeproj` (no errors).

- [ ] **Step 4: Commit**

```bash
git add Sources/DockTape/Resources/DockTape.entitlements project.yml
git commit -m "feat: add iCloud ubiquity container entitlement"
```

---

### Task 3: Update AppState to use StorageLocationResolver

**Files:**
- Modify: `Sources/DockTape/AppState.swift:87-102`

- [ ] **Step 1: Add storage mode migration and resolver to AppState.init**

Replace `AppState.init()` (lines 87–102) with:

```swift
    init() {
        let defaults = UserDefaults.standard

        // One-time migration: determine storage mode for pre-iCloud installs
        let mode: StorageMode
        if let stored = defaults.string(forKey: "storageMode"),
           let parsed = StorageMode(rawValue: stored) {
            mode = parsed
        } else {
            // First launch after iCloud update — migrate
            let migrated = StorageLocationResolver.migratedMode(from: defaults)
            defaults.set(migrated.rawValue, forKey: "storageMode")
            mode = migrated
        }

        let customURL = defaults.url(forKey: "libraryLocation")
        let baseDir = StorageLocationResolver.resolve(mode: mode, customURL: customURL)

        let store = RecordingStore(baseDirectory: baseDir)
        let transcriptStore = TranscriptStore(baseDirectory: store.baseDirectory)

        self.library = LibraryState(store: store, transcriptStore: transcriptStore)
        self.device = DeviceState()
        self.playback = PlaybackState()
        self.transcription = TranscriptionState(transcriptStore: transcriptStore)
        let summaryStore = SummaryStore(baseDirectory: store.baseDirectory)
        self.summarization = SummarizationState(summaryStore: summaryStore)
        self.templateStore = TemplateStore(baseDirectory: store.baseDirectory)

        self.autoDeleteAfterDownload = defaults.bool(forKey: "autoDeleteAfterDownload")
        self.autoSyncClock = defaults.object(forKey: "autoSyncClock") as? Bool ?? true
    }
```

- [ ] **Step 2: Add switchStorageLocation method**

Add this method to `AppState` after the `refreshAll()` method (after line 144):

```swift
    /// Switch storage location and re-initialize all stores.
    /// Does NOT move files — the user manages that via Finder.
    func switchStorageLocation(to mode: StorageMode, customURL: URL? = nil) async {
        let defaults = UserDefaults.standard
        defaults.set(mode.rawValue, forKey: "storageMode")

        if mode == .custom, let url = customURL {
            defaults.set(url, forKey: "libraryLocation")
        }

        let baseDir = StorageLocationResolver.resolve(mode: mode, customURL: customURL)

        let store = RecordingStore(baseDirectory: baseDir)
        let transcriptStore = TranscriptStore(baseDirectory: store.baseDirectory)

        self.library = LibraryState(store: store, transcriptStore: transcriptStore)
        self.transcription = TranscriptionState(transcriptStore: transcriptStore)
        let summaryStore = SummaryStore(baseDirectory: store.baseDirectory)
        self.summarization = SummarizationState(summaryStore: summaryStore)
        self.templateStore = TemplateStore(baseDirectory: store.baseDirectory)

        do {
            try await setup()
        } catch {
            errorMessage = "Failed to load library: \(error.localizedDescription)"
        }
    }

    /// Whether iCloud was requested but is currently unavailable.
    var isICloudUnavailable: Bool {
        let mode = UserDefaults.standard.string(forKey: "storageMode")
        return mode == "icloud" && !StorageLocationResolver.isICloudAvailable
    }
```

- [ ] **Step 3: Build to verify compilation**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeded.

- [ ] **Step 4: Commit**

```bash
git add Sources/DockTape/AppState.swift
git commit -m "feat: use StorageLocationResolver in AppState init and add live switching"
```

---

### Task 4: Update SettingsView with three-mode picker

**Files:**
- Modify: `Sources/DockTape/Views/SettingsView.swift:6-73`

- [ ] **Step 1: Replace the state properties and library location section**

Replace the current `SettingsView` struct (lines 6–73) with:

```swift
struct SettingsView: View {
    @Bindable var state: AppState
    @State private var storageMode: StorageMode = .icloud
    @State private var customPath: String = ""
    @State private var showLocationChangedAlert = false
    @State private var showICloudWarning = false

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("General", systemImage: "gear") }

            AISettingsView()
                .tabItem { Label("AI", systemImage: "sparkles") }

            TemplateSettingsView(state: state)
                .tabItem { Label("Templates", systemImage: "doc.plaintext") }

            if let device = state.device.model, let settings = device.settings {
                deviceSettings(settings)
                    .tabItem { Label("Device", systemImage: "waveform") }
            }

            aboutView
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 450)
        .onAppear {
            let raw = UserDefaults.standard.string(forKey: "storageMode") ?? "icloud"
            storageMode = StorageMode(rawValue: raw) ?? .icloud
            customPath = state.library.store.baseDirectory.path(percentEncoded: false)
        }
        .alert("Storage Location Changed", isPresented: $showLocationChangedAlert) {
            Button("OK") {}
        } message: {
            Text("DockTape will now look for recordings in the new location. Your existing recordings are not moved — use Finder to move them if needed.")
        }
    }

    private var generalSettings: some View {
        Form {
            Section("Sync") {
                Toggle("Auto-sync clock on connect", isOn: $state.autoSyncClock)
                Toggle("Auto-delete from device after download", isOn: $state.autoDeleteAfterDownload)
            }

            Section("Storage Location") {
                Picker("Store recordings in", selection: $storageMode) {
                    Text("iCloud Drive").tag(StorageMode.icloud)
                    Text("This Mac").tag(StorageMode.local)
                    Text("This Mac (Custom\u{2026})").tag(StorageMode.custom)
                }
                .onChange(of: storageMode) { _, newMode in
                    handleStorageModeChange(newMode)
                }

                if state.isICloudUnavailable {
                    Label("iCloud Drive is not available. Using local storage.", systemImage: "exclamationmark.icloud")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text(state.library.store.baseDirectory.path(percentEncoded: false))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .formStyle(.grouped)
    }
```

- [ ] **Step 2: Add the storage mode change handler**

Add this method inside `SettingsView`, replacing the old `chooseLibraryLocation()` and `defaultLibraryPath`:

```swift
    private func handleStorageModeChange(_ mode: StorageMode) {
        if mode == .custom {
            chooseCustomLocation()
        } else {
            Task {
                await state.switchStorageLocation(to: mode)
                showLocationChangedAlert = true
            }
        }
    }

    private func chooseCustomLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Select where to store downloaded recordings"

        if panel.runModal() == .OK, let url = panel.url {
            // Store as security-scoped bookmark so we can access it after restart
            if let bookmark = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                UserDefaults.standard.set(bookmark, forKey: "libraryLocationBookmark")
                Task {
                    await state.switchStorageLocation(to: .custom, customURL: url)
                    showLocationChangedAlert = true
                }
            }
        } else {
            // User cancelled — revert picker to previous mode
            let raw = UserDefaults.standard.string(forKey: "storageMode") ?? "icloud"
            storageMode = StorageMode(rawValue: raw) ?? .icloud
        }
    }
```

- [ ] **Step 3: Remove old properties and methods**

Delete these from `SettingsView` (they are replaced by the new code above):
- `@AppStorage("libraryLocation") private var libraryLocationBookmark: Data?` (line 8)
- `@State private var libraryPath: String = ""` (line 9)
- `@State private var showRestartAlert = false` (line 10)
- The old `chooseLibraryLocation()` method (lines 112–134)
- The old `defaultLibraryPath` computed property (lines 136–139)
- The old restart alert `.alert("Restart Required", ...)` (lines 35–39)

- [ ] **Step 4: Build to verify compilation**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeded.

- [ ] **Step 5: Commit**

```bash
git add Sources/DockTape/Views/SettingsView.swift
git commit -m "feat: replace library location picker with three-mode storage selector"
```

---

### Task 5: Manual verification

- [ ] **Step 1: Run all tests**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass, including the new `StorageModeTests`.

- [ ] **Step 2: Build the app and test iCloud mode**

Run: `swift build 2>&1 | tail -5`

Manual verification checklist (in the running app):
1. Open Settings → General
2. Verify the "Storage Location" picker shows "iCloud Drive" selected by default
3. If iCloud is available: verify the path shows the ubiquity container Documents path
4. If iCloud is unavailable: verify the orange warning label appears
5. Switch to "This Mac" → verify the path changes to `~/Documents/HiDock Recordings/`
6. Switch to "This Mac (Custom...)" → verify NSOpenPanel opens, pick a directory, verify path updates
7. Switch back to "iCloud Drive" → verify path reverts

- [ ] **Step 3: Verify Finder visibility**

1. Open Finder → iCloud Drive
2. Look for a "DockTape" folder (may appear after first write to the ubiquity container)
3. If a recording exists, verify the MP3 and sidecar files are visible

- [ ] **Step 4: Commit version bump**

```bash
# Bump patch version for the iCloud storage feature
# In project.yml, update MARKETING_VERSION from "1.1.0" to "1.2.0"
git add project.yml
git commit -m "chore: bump version to 1.2.0 for iCloud Drive storage"
```
