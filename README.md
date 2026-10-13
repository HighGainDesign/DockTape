# DockTape

**HiDock Manager** — a native macOS app for managing recordings from your [HiDock](https://hidock.com) device (P1, P1 Mini, H1, H1E).

Import, transcribe, diarize, and manage recordings on your Mac. Transcription and diarization run on-device; optional AI summaries use a cloud or local provider. Tested with HiDock P1.

## Features

- **Three-pane layout** — sidebar (folders/devices), recording list, detail pane with tabbed Info/Transcript/Summary
- **USB device management** — connect via USB, browse files, monitor battery and storage
- **Import recordings** — import from device with auto HDA-to-MP3 conversion
- **Local transcription** — speech-to-text using Parakeet ASR via [FluidAudio](https://github.com/FluidInference/FluidAudio), runs on Apple Silicon
- **Speaker diarization** — identify and label different speakers using Sortformer via FluidAudio
- **AI summaries** — summarize transcripts via Anthropic, OpenAI, OpenRouter, or local models (Ollama, LM Studio). 7 built-in templates (Meeting, Lecture, Interview, Memo, Discussion, Consultation, Coaching/Counseling), custom templates, action item checkboxes
- **iCloud Drive storage** — recordings sync across Macs via iCloud Drive. Local and custom storage locations also supported
- **Multiple export formats** — Markdown, plain text, SRT subtitles, JSONL, JSON
- **Audio playback** — built-in player with variable speed (0.5x–3x)
- **Library management** — folders, search, sort, filter by recording type and date
- **Smart summarization** — hit Summarize on any recording; auto-transcribes first if needed
- **Menu bar extra** — quick device status from the menu bar
- **CLI tool** — `hidock` command for headless operation

## Download

**[Download DockTape](https://github.com/HighGainDesign/DockTape/releases/latest)** — signed `.dmg`.

As of October 13, 2026, the latest published release is **v1.0.0**. The features described above reflect the current source (**v1.2.0**), which is awaiting final interface acceptance. Building from source includes changes that are not yet in the published download.

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon Mac (for on-device transcription)
- HiDock device (P1, P1 Mini, H1, or H1E) connected via USB

## Building

### macOS App (.app bundle)

Requires [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`):

```bash
./scripts/build-app.sh              # Build Release .app
./scripts/build-app.sh --install    # Build and copy to /Applications
```

The Xcode project is generated from `project.yml` — don't edit `DockTape.xcodeproj` directly.

### CLI

```bash
swift build
swift run hidock help
```

### Tests

```bash
swift test
./scripts/test-playback.sh   # App playback regression checks (macOS)
./scripts/test-import.sh     # App import and storage regression checks (macOS)
```

### Releases

Pushing a tag matching `MARKETING_VERSION` (for example, `v1.2.0`) runs the GitHub release workflow. It tests the source, builds with Xcode 26.6, signs with Developer ID, notarizes and staples both the app and DMG, and publishes the DMG with a SHA-256 checksum. A manual workflow run produces a test artifact without publishing a release. Local packaging can be tested with `./scripts/release.sh`.

The workflow requires encrypted Actions repository secrets: `DEVELOPER_ID_CERTIFICATE_BASE64` (encrypted PKCS12), `DEVELOPER_ID_CERTIFICATE_PASSWORD`, `PROVISIONING_PROFILE_BASE64`, `APPLE_ID` (`dev@highgain.design`), `APPLE_APP_SPECIFIC_PASSWORD`, and `APPLE_TEAM_ID` (`UX8BPNLPX5`). Use the **DockTape Developer ID** provisioning profile. Credentials are installed in a temporary runner Keychain and removed after the job. Never put certificates, private keys, passwords, or provisioning profiles in source control or release assets.

The icon source is `Sources/DockTape/Resources/AppIcon.icon`, shared for macOS and future iOS use. Xcode generates fallback images for macOS 14–25.

## Architecture

- **DockTape** — AppKit macOS window shell hosting SwiftUI views; Xcode target generated from `project.yml`
- **HiDockKit** — shared core: Jensen protocol, device management, storage, transcription, summaries; declares macOS and iOS support
- **HiDockKitUSB** — macOS USB transport backed by vendored libusb
- **HiDockCLI** — command-line interface using HiDockKit and HiDockKitUSB

An iOS/iPadOS app is planned; there is no iOS app target yet.

Recordings are stored in iCloud Drive (default), `~/Documents/HiDock Recordings/`, or a custom directory — configurable in Settings. Transcripts and summaries live as JSON sidecar files alongside each MP3. The filesystem is the source of truth — no database.

## Development

Build and test commands are listed above. Local developer notes and agent handoffs are intentionally excluded from this repository.

## License

MIT
