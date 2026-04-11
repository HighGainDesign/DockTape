# DockTape — Developer Reference

Native macOS app for managing HiDock recordings (P1, P1 Mini, H1, H1E).
Download, transcribe, diarize, and export — entirely on-device. Tested with P1.

**Stack:** Swift 5.10+, SwiftUI, SPM, macOS 14+, Apple Silicon required
**Status:** Three-pane redesign, AI summaries, and template redesign merged. Playback progress deferred (needs AppKit window host).

## Commands

```bash
# Build & run CLI
swift build
swift run hidock help

# Tests (145 unit tests; 3 Keychain tests need unlocked keychain)
swift test

# macOS app (requires: brew install xcodegen)
./scripts/build-app.sh              # Release .app
./scripts/build-app.sh --install    # Build + copy to /Applications
```

The Xcode project is generated from `project.yml` — never edit `.xcodeproj` directly.

## Architecture

Three SPM targets sharing one library:

- **HiDockKit** (library) — all core logic
- **DockTape** (SwiftUI app) — UI shell, depends on HiDockKit
- **HiDockCLI** (executable) — CLI, depends on HiDockKit

### HiDockKit Modules

| Module | Responsibility |
|---|---|
| USB | libusb wrapper, IOKit hotplug monitor, `USBConnectionProtocol` for mocking |
| Protocol | Jensen wire format: frame codec, 18 commands, async transport with sequence tracking |
| Device | `DeviceManager` actor — high-level queries, file transfer, state via `@Observable DeviceModel` |
| Storage | `RecordingStore` (filesystem scan), HDA→MP3 conversion, metadata from filenames |
| Transcription | Parakeet ASR via FluidAudio, Sortformer diarization, pipeline merging, JSON persistence |
| Summarization | LLM-powered summaries via cloud API (Anthropic/OpenAI/OpenRouter/custom). `Summary` model, `SummaryStore` actor, `LLMProvider` protocol, `Template` struct, `TemplateStore` actor (7 built-in + user-created templates) |
| Sync | `SyncEngine` actor — file sync orchestration; `RecordingPipeline` — end-to-end download→convert→transcribe |
| Utilities | Filename parsing, duration estimation, endian helpers |

### Data Flow

USB device → Jensen protocol frames → DeviceManager → SyncEngine → RecordingStore (MP3 on disk) → TranscriptionPipeline → TranscriptStore (JSON on disk) → SummarizationState → LLMProvider → SummaryStore (JSON on disk)

## Key Design Decisions

1. **Filesystem as source of truth** — no database. MP3 files in `~/Documents/HiDock Recordings/` are canonical. Transcripts as `{basename}.transcript.json`, summaries as `{basename}.summary.json` alongside.
2. **Actors for concurrency** — DeviceManager, SyncEngine, RecordingPipeline, TranscriptStore, JensenTransport are all actors. No manual locks.
3. **Protocol-driven USB** — `USBConnectionProtocol` enables full mock testing of the protocol layer without hardware.
4. **Graceful degradation** — diarization is optional; transcription models download on-demand (FluidAudio caches them).
5. **Self-contained app** — all logic lives in HiDockKit. No scattered CLI tools or external services.
6. **Per-pane inline toolbars** — SwiftUI NavigationSplitView can't do per-column NSToolbar. We use `.safeAreaInset(edge: .top)` with `.background(.bar)`. Window toolbar is hidden. Real fix requires AppKit NSSplitViewController + NSTrackingSeparatorToolbarItem.
7. **LLM API keys in Keychain** — user brings their own key (Anthropic/OpenAI/OpenRouter/custom). Stored via Security.framework, no third-party wrapper. Custom provider reuses OpenAIProvider with configurable baseURL (Ollama, LM Studio, vLLM).
8. **Three-pane layout** — NavigationSplitView: sidebar (folders/devices), recording list, detail pane with tabbed Info/Transcript/Summary.
9. **Playback progress deferred** — macOS App Nap throttles all timer mechanisms (TimelineView, periodic observers, Timer). Reliable progress tracking requires an AppKit window host. Scrubber and transcript highlighting are intentionally disabled until then.
10. **"Import" not "Download"** — user-facing label for bringing recordings from device into the library. Internal method names still use `downloadFile`.
11. **Keychain service** = `KeychainHelper.aiService` (`design.highgain.docktape.ai`). All callers use this constant.
12. **Data-driven templates** — `Template` struct + `TemplateStore` actor replace the old `SummaryTemplate` enum. 7 built-in templates, user-created templates persisted as `.templates.json`, one-shot custom prompts. Smart quote sanitization handles malformed JSON from local LLMs.
13. **UI consistency** — all toolbar buttons must use the same style (bordered, icon+text, `.controlSize(.small)`). Never ship mismatched button styles.

## Code Conventions

- **Actors** for shared mutable state, `@Observable` for view state
- **Protocol suffix** for abstractions (`USBConnectionProtocol`, `TranscriptionEngine`)
- **Manager/Store/Engine** suffixes for coordinators
- Three error hierarchies: `USBError` → `ProtocolError` → `HiDockError`
- `@Sendable` closures for async callbacks
- Public API marked `public`, library internals stay `internal`

## Safety & Permissions

- USB access requires **no sandbox** — entitlements disable it (`ENABLE_USER_SCRIPT_SANDBOXING: NO`)
- Code signing disabled for local dev (`CODE_SIGN_IDENTITY: "-"`)
- libusb is vendored as a static library in `Vendor/libusb/`
- CLibUSB is a C bridging module (shim header only)

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
