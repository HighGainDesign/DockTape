# iCloud Drive Storage for DockTape

**Date:** 2026-04-14
**Status:** Approved

## Goal

Make iCloud Drive the default storage location for DockTape recordings, transcripts, summaries, and templates. Recordings should be visible in Finder (macOS) and Files.app (iOS/iPadOS). Users who don't use iCloud can store locally or pick a custom directory.

## Storage Modes

Three modes, selectable in Settings → General:

| Mode | Base Directory | Default |
|------|---------------|---------|
| **iCloud Drive** | Ubiquity container `Documents/` | Yes |
| **This Mac** | `~/Documents/HiDock Recordings/` | — |
| **This Mac (Custom)** | User-picked via NSOpenPanel | — |

### iCloud Drive path

```
~/Library/Mobile Documents/iCloud~design~highgain~docktape/Documents/
```

Resolved at runtime via `FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.design.highgain.docktape")`, then appending `Documents/`.

Only the `Documents/` subdirectory is visible to the user in Files.app. All recordings, sidecars, folders, and `.templates.json` live here.

### Unavailability fallback

If the user's preference is iCloud but `url(forUbiquityContainerIdentifier:)` returns `nil` (not signed in, iCloud Drive disabled):

- Fall back to the local default path (`~/Documents/HiDock Recordings/`)
- Show a non-modal warning banner in the main window: "iCloud Drive is not available. Using local storage."
- Persist the preference as `icloud` so it activates automatically when iCloud becomes available

## Settings UI

Replace the current "Library Location" row with a `Picker`:

```
Storage Location:  [iCloud Drive ▾]
                   ├─ iCloud Drive
                   ├─ This Mac
                   └─ This Mac (Custom…)   ← opens NSOpenPanel on selection
```

When the user changes the storage mode, show an informational alert:

> "DockTape will now look for recordings in [new location]. Your existing recordings are not moved — use Finder to move them if needed."

After dismissal, re-initialize stores with the new base directory. No app restart required.

## UserDefaults Schema

| Key | Type | Values | Default |
|-----|------|--------|---------|
| `storageMode` | String | `"icloud"`, `"local"`, `"custom"` | `"icloud"` |
| `libraryLocation` | URL | Custom directory URL | — |
| `libraryLocationBookmark` | Data | Security-scoped bookmark | — |

The existing `libraryLocation` and `libraryLocationBookmark` keys are reused for the custom path. They are only read when `storageMode == "custom"`.

### Migration from pre-iCloud installs

On first launch after this update:

- If `libraryLocation` exists in UserDefaults (user had a custom path) → set `storageMode = "custom"`
- If `libraryLocation` is nil (user was on the default) → set `storageMode = "icloud"`

This is a one-time migration. Existing users keep their current location. New installs default to iCloud Drive.

## Architecture Changes

### What changes

1. **`AppState.init`** — resolve `baseDirectory` from `storageMode`:
   - `"icloud"` → ubiquity container `Documents/`, fallback to local default
   - `"local"` → `~/Documents/HiDock Recordings/`
   - `"custom"` → resolve from `libraryLocationBookmark`

2. **`AppState` storage mode switching** — new method to re-initialize all stores (`RecordingStore`, `TranscriptStore`, `SummaryStore`, `TemplateStore`) with a new base directory and refresh the UI. Called from Settings when the user changes the picker.

3. **`SettingsView`** — replace library location section with the three-mode picker described above.

4. **Entitlements** — add:
   ```xml
   <key>com.apple.developer.ubiquity-container-identifiers</key>
   <array>
       <string>iCloud.design.highgain.docktape</string>
   </array>
   ```

5. **`project.yml`** — add the iCloud entitlement to the entitlements properties.

6. **Code signing** — must switch from ad-hoc (`-`) to a Developer ID with iCloud capability. This is a manual step outside the codebase.

### What doesn't change

- **`RecordingStore`** — already takes `baseDirectory: URL`. iCloud container is just a different URL.
- **`TranscriptStore`**, **`SummaryStore`**, **`TemplateStore`** — same: URL-parameterized, no changes.
- **Sidecar file pattern** — iCloud Drive syncs the whole folder tree transparently.
- **Recording pipeline** — writes to `baseDirectory` as before.
- **`RecordingMetadata`** model — unchanged.

### No migration logic

Switching storage modes does **not** move files. The app points at the new directory; the user moves files via Finder or Files.app. This avoids:

- Complex copy/move progress UI
- Partial-transfer error handling
- Conflicts between iCloud sync and local file operations

## Entitlements & Signing

### Current state

- `com.apple.security.device.usb` — USB access for HiDock
- `com.apple.security.files.user-selected.read-write` — custom directory access
- Code sign: ad-hoc (`CODE_SIGN_IDENTITY: "-"`)

### After this change

- Add `com.apple.developer.ubiquity-container-identifiers`
- Code sign: Developer ID (manual setup, not in project.yml)

### Future sandbox compatibility

Adding App Sandbox later requires:

- `com.apple.security.app-sandbox: true`
- `com.apple.security.network.client: true` (for AI summarization)
- "This Mac" default path would change to the sandbox container directory
- iCloud Drive and custom (security-scoped bookmark) paths work unchanged under sandbox

No architectural changes needed — the three-mode design is sandbox-ready.

## File Layout in iCloud Container

```
~/Library/Mobile Documents/iCloud~design~highgain~docktape/Documents/
├── REC_20260414_100000.mp3
├── REC_20260414_100000.transcript.json
├── REC_20260414_100000.txt
├── REC_20260414_100000.summary.json
├── Meetings/
│   ├── standup.mp3
│   ├── standup.transcript.json
│   └── standup.summary.json
└── .templates.json
```

Identical structure to the current local layout. No changes to file organization.

## Scope

This spec covers macOS only. The iOS app (Phase 3) will read from the same iCloud container using the same `url(forUbiquityContainerIdentifier:)` API, requiring no additional storage design work.
