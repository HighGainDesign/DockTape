#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

swift build
BIN_PATH="$(swift build --show-bin-path)"
MODULES="$BIN_PATH/Modules"
OUTPUT=".build/release-validation/playback-tests"
mkdir -p "$(dirname "$OUTPUT")"
swiftc -swift-version 5 -parse-as-library -I "$MODULES" \
    -I .build/checkouts/FluidAudio/Sources/FastClusterWrapper/include \
    -I .build/checkouts/FluidAudio/Sources/MachTaskSelfWrapper/include \
    Sources/HiDockKit/Storage/RecordingFileAccess.swift \
    Sources/HiDockKit/Storage/SharedLibrary/CoordinatedFileAccess.swift \
    Sources/DockTape/State/PlaybackState.swift \
    Sources/DockTape/State/RecordingContentState.swift Tests/DockTapePlaybackTests.swift \
    -o "$OUTPUT"
"$OUTPUT"
