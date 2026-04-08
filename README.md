# DockTape

**HiDock Manager** — a native macOS app for managing recordings from your [HiDock](https://hidock.com) device.

Download, transcribe, diarize, and manage recordings entirely on-device. No cloud services required.

## Features

- **USB device management** — connect via USB, browse files, monitor battery and storage
- **One-click sync** — download recordings from device, auto-convert HDA to MP3
- **Local transcription** — speech-to-text using Parakeet ASR via [FluidAudio](https://github.com/FluidInference/FluidAudio), runs on Apple Silicon
- **Speaker diarization** — identify and label different speakers using Sortformer via FluidAudio
- **Speaker renaming** — rename detected speakers for readable transcripts
- **Multiple export formats** — plain text, SRT subtitles, JSONL, JSON
- **Audio playback** — built-in player with variable speed (0.5x–3x), seek-to-timestamp from transcript
- **Library management** — search, sort, filter by recording type and date
- **Menu bar extra** — quick device status from the menu bar
- **CLI tool** — `hidock` command for headless operation

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon Mac (for on-device transcription)
- HiDock H1 device connected via USB

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
```

## Architecture

- **DockTape** — SwiftUI macOS app
- **HiDockKit** — shared library: USB communication (Jensen protocol), storage, transcription pipeline
- **HiDockCLI** — command-line interface using HiDockKit

Recordings are stored in `~/Documents/HiDock Recordings/`. The filesystem is the source of truth — no database or metadata files. MP3 files on disk are the canonical record.

## Development

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for architecture, conventions, and detailed build instructions.

## License

MIT
