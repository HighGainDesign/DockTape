# DockTape — Developer Reference

Native macOS app for managing HiDock recordings (P1, P1 Mini, H1, H1E).
Download, transcribe, diarize, and export — entirely on-device. Tested with P1.

**Stack:** Swift 5.10+, SwiftUI, SPM, macOS 14+, Apple Silicon required
**Status:** MVP complete — library, playback, transcription, diarization, export all wired

## Commands

```bash
# Build & run CLI
swift build
swift run hidock help

# Tests (91 unit tests)
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
| Sync | `SyncEngine` actor — file sync orchestration; `RecordingPipeline` — end-to-end download→convert→transcribe |
| Utilities | Filename parsing, duration estimation, endian helpers |

### Data Flow

USB device → Jensen protocol frames → DeviceManager → SyncEngine → RecordingStore (MP3 on disk) → TranscriptionPipeline → TranscriptStore (JSON on disk)

## Key Design Decisions

1. **Filesystem as source of truth** — no database. MP3 files in `~/Documents/HiDock Recordings/` are canonical. Transcripts stored as `{basename}.transcript.json` alongside.
2. **Actors for concurrency** — DeviceManager, SyncEngine, RecordingPipeline, TranscriptStore, JensenTransport are all actors. No manual locks.
3. **Protocol-driven USB** — `USBConnectionProtocol` enables full mock testing of the protocol layer without hardware.
4. **Graceful degradation** — diarization is optional; transcription models download on-demand (FluidAudio caches them).
5. **Self-contained app** — all logic lives in HiDockKit. No scattered CLI tools or external services.

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
