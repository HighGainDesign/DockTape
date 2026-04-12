# DockTape

**HiDock Manager** — a native macOS app for managing recordings from your [HiDock](https://hidock.com) device (P1, P1 Mini, H1, H1E).

Download, transcribe, diarize, and manage recordings entirely on-device. No cloud services required. Tested with HiDock P1.

## Features

- **Three-pane layout** — sidebar (folders/devices), recording list, detail pane with tabbed Info/Transcript/Summary
- **USB device management** — connect via USB, browse files, monitor battery and storage
- **Import recordings** — import from device with auto HDA-to-MP3 conversion
- **Local transcription** — speech-to-text using Parakeet ASR via [FluidAudio](https://github.com/FluidInference/FluidAudio), runs on Apple Silicon
- **Speaker diarization** — identify and label different speakers using Sortformer via FluidAudio
- **AI summaries** — summarize transcripts via Anthropic, OpenAI, OpenRouter, or local models (Ollama, LM Studio). 7 built-in templates (Meeting, Lecture, Interview, Memo, Discussion, Consultation, Coaching/Counseling), custom templates, action item checkboxes
- **Multiple export formats** — plain text, SRT subtitles, JSONL, JSON
- **Audio playback** — built-in player with variable speed (0.5x–3x)
- **Library management** — folders, search, sort, filter by recording type and date
- **Menu bar extra** — quick device status from the menu bar
- **CLI tool** — `hidock` command for headless operation

## Download

**[Download DockTape v1.0.0](https://github.com/HighGainDesign/docktape/releases/latest)** — signed and notarized `.dmg`, ready to use.

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
```

## Architecture

- **DockTape** — SwiftUI macOS app
- **HiDockKit** — shared library: USB communication (Jensen protocol), storage, transcription pipeline
- **HiDockCLI** — command-line interface using HiDockKit

Recordings are stored in `~/Documents/HiDock Recordings/` with transcripts and summaries as JSON sidecar files. The filesystem is the source of truth — no database.

## Development

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for architecture, conventions, and detailed build instructions.

## License

MIT
