# DockTape — Developer Reference

Native macOS app for managing HiDock recordings (P1, P1 Mini, H1, H1E).
Download, transcribe, diarize, and export — entirely on-device. Tested with P1.

**Stack:** Swift 5.10+, AppKit (NSSplitViewController, NSToolbar) + SwiftUI (hosted views), SPM, macOS 14+ / iOS 17+, Apple Silicon required
**Status:** v1.2.0. iCloud Drive storage (default), device busy guards, auto-transcribe-then-summarize. Phase 1 iOS platform abstraction complete. HiDockKit builds for iOS Simulator.

## Commands

```bash
# Build & run CLI
swift build
swift run hidock help

# Tests (163 unit tests; 3 Keychain tests need unlocked keychain)
swift test

# macOS app (requires: brew install xcodegen)
./scripts/build-app.sh              # Release .app
./scripts/build-app.sh --install    # Build + copy to /Applications
```

The Xcode project is generated from `project.yml` — never edit `.xcodeproj` directly.

## Architecture

Four SPM targets:

- **HiDockKit** (library, macOS + iOS) — cross-platform core: protocol, device management, storage, transcription, summarization
- **HiDockKitUSB** (library, macOS only) — USB transport: `USBConnection`, `USBDeviceMonitor`, `DeviceProbe`. Depends on HiDockKit + CLibUSB
- **DockTape** (AppKit + SwiftUI app) — AppKit window shell hosting SwiftUI views, depends on HiDockKit + HiDockKitUSB
- **HiDockCLI** (executable) — CLI, depends on HiDockKit + HiDockKitUSB

### HiDockKit Modules

| Module | Responsibility |
|---|---|
| Protocol | `DeviceTransport` protocol (transport abstraction), Jensen wire format: frame codec, 18 commands, async transport with sequence tracking |
| Device | `DeviceManager` actor — high-level queries, file transfer, state via `@Observable DeviceModel` |
| Storage | `RecordingStore` (filesystem scan), HDA→MP3 conversion, metadata from filenames, `StorageMode`/`StorageLocationResolver` (iCloud/local/custom) |
| Transcription | Parakeet ASR via FluidAudio, Sortformer diarization, pipeline merging, JSON persistence |
| Summarization | LLM-powered summaries via cloud API (Anthropic/OpenAI/OpenRouter/custom). `Summary` model, `SummaryStore` actor, `LLMProvider` protocol, `Template` struct, `TemplateStore` actor (7 built-in + user-created templates) |
| Sync | `SyncEngine` actor — file sync orchestration; `RecordingPipeline` — end-to-end download→convert→transcribe |
| Utilities | Filename parsing, duration estimation, endian helpers |

### Data Flow

USB device → Jensen protocol frames → DeviceManager → SyncEngine → RecordingStore (MP3 on disk) → TranscriptionPipeline → TranscriptStore (JSON on disk) → SummarizationState → LLMProvider → SummaryStore (JSON on disk)

## Key Design Decisions

1. **Filesystem as source of truth** — no database. MP3 files stored in iCloud Drive (default), `~/Documents/HiDock Recordings/`, or user-chosen custom directory. `StorageMode` enum + `StorageLocationResolver` in `StorageMode.swift` handle resolution. Transcripts as `{basename}.transcript.json`, summaries as `{basename}.summary.json` alongside. Recording mode persisted as `com.highgain.docktape.mode` xattr on the MP3 to survive renames.
2. **Actors for concurrency** — DeviceManager, SyncEngine, RecordingPipeline, TranscriptStore, JensenTransport are all actors. No manual locks.
3. **Protocol-driven transport** — `DeviceTransport` protocol enables full mock testing of the protocol layer without hardware. Platform implementations: `USBConnection` (macOS), `EAConnection` (iOS, future).
4. **Graceful degradation** — diarization is optional; transcription models download on-demand (FluidAudio caches them).
5. **Self-contained app** — all logic lives in HiDockKit. No scattered CLI tools or external services.
6. **AppKit window host (Notes-style)** — Full AppKit shell: `NSSplitViewController` with three panes (sidebar, content list, detail) + `NSToolbar` with `NSTrackingSeparatorToolbarItem`. Sidebar is full-height into the titlebar. Toolbar spans only the detail pane. SwiftUI views hosted via `NSHostingController`. Context-sensitive toolbar items (library vs. device). Toolbar density toggle via View menu.
7. **LLM API keys in Keychain** — user brings their own key (Anthropic/OpenAI/OpenRouter/custom). Stored via Security.framework, no third-party wrapper. Custom provider reuses OpenAIProvider with configurable baseURL (Ollama, LM Studio, vLLM).
8. **Three-pane layout** — NSSplitViewController: sidebar (folders/devices), recording list, detail pane with tabbed Info/Transcript/Summary. Two tracking separators: sidebar|list and list|detail. Sort/filter in NSToolbar left of detail zone. All item actions (play, transcribe, summarize, import, delete, refresh) in detail zone toolbar, context-sensitive (library vs. device).
9. **Playback progress** — `TimelineView(.animation)` reads `AVPlayer.currentTime()` directly each display frame, bypassing `@Observable` coalescing. `addBoundaryTimeObserver` fires at exact segment start times for transcript highlighting. `addPeriodicTimeObserver` (0.25s) only caches `progress` for seek-on-pause. Interactive scrubber in Now Playing bar (pinned to detail pane bottom). Auto-scroll to active segment.
10. **"Import" not "Download"** — user-facing label for bringing recordings from device into the library. Internal method names still use `downloadFile`.
11. **Keychain service** = `KeychainHelper.aiService` (`design.highgain.docktape.ai`). All callers use this constant.
12. **Data-driven templates** — `Template` struct + `TemplateStore` actor replace the old `SummaryTemplate` enum. 7 built-in templates, user-created templates persisted as `.templates.json`, one-shot custom prompts. Smart quote sanitization handles malformed JSON from local LLMs.
13. **UI consistency** — NSToolbar items use `isBordered = true` with SF Symbols and accessibility descriptions. Toolbar density (icon only, text only, icon+text) toggled via View > Toolbar Style.
14. **DeviceTransport protocol** — byte-level transport abstraction (`send`/`receive` Data, `open`, `close`). Platform implementations: `USBConnection` (macOS, libusb), `EAConnection` (iOS, ExternalAccessory — future). `JensenTransport` handles frame accumulation on top. `DeviceManager` takes `any DeviceTransport`.
15. **HiDockKitUSB target split** — USB-specific code (USBConnection, USBDeviceMonitor, DeviceProbe) lives in a separate macOS-only target. HiDockKit is cross-platform (macOS + iOS). CLibUSB is macOS-only. FluidAudio confirmed iOS-compatible. **iOS targets must depend only on HiDockKit, never HiDockKitUSB or CLibUSB** (Package.swift warns).
16. **iOS via ExternalAccessory (MFi)** — HiDock devices have built-in MFi auth chips. HiNotes iOS app confirmed working over USB cable with any USB-C cable. DockTape iOS will use `EASession` to get a byte stream, then pipe through the same `JensenTransport` → `DeviceManager` stack. Protocol strings need to be extracted from HiNotes IPA (Phase 2).

## Code Conventions

- **Actors** for shared mutable state, `@Observable` for view state
- **Noun protocols** for abstractions (`DeviceTransport`, `TranscriptionEngine`) — no `Protocol` suffix
- **Manager/Store/Engine** suffixes for coordinators
- Three error hierarchies: `USBError` → `ProtocolError` → `HiDockError`
- `@Sendable` closures for async callbacks
- Public API marked `public`, library internals stay `internal`

## Safety & Permissions

- USB access requires **no sandbox** — entitlements disable it (`ENABLE_USER_SCRIPT_SANDBOXING: NO`)
- Automatic code signing with Developer ID (team `UX8BPNLPX5`)
- iCloud entitlements: `ubiquity-container-identifiers`, `icloud-container-identifiers`, `icloud-services` (CloudDocuments) — container `iCloud.design.highgain.docktape`
- libusb is vendored as a static library in `Vendor/libusb/`
- CLibUSB is a C bridging module (shim header only)
- Device operations are guarded by `isDeviceBusy` — only one USB command in flight at a time

## Domain Vocabulary

- **Jensen** — HiDock's USB wire protocol (magic bytes, framed commands)
- **HDA** — HiDock's proprietary recording format (stripped header = valid MP3)
- **Parakeet ASR** — NVIDIA's speech recognition model, run locally via FluidAudio
- **Sortformer** — speaker diarization model
- **BCD coding** — binary-coded decimal used in device timestamps

## Gotchas

- Jensen frames can split across USB packets — transport must accumulate until full frame received
- HDA→MP3 conversion is just stripping a fixed-size header, not re-encoding
- Transcription models are large (~1.5 GB) and download on first use — `prepare()` is async
- Device commands are strictly sequential (one in-flight at a time via JensenTransport actor)
- `project.yml` is the source for the Xcode project; regenerate after changing targets/settings
- NSSplitView panes may not be resizable immediately after launch (known intermittent issue); resizing works after interacting with the window
- `TimelineView` is the only reliable way to drive continuous UI updates from AVPlayer in SwiftUI — `@Observable` property mutation at >2Hz gets coalesced/dropped
