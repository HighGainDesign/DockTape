#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

swift build
BIN_PATH="$(swift build --show-bin-path)"
MODULES="$BIN_PATH/Modules"
OUTPUT=".build/release-validation/playback-tests"
mkdir -p "$(dirname "$OUTPUT")"
OBJECTS=()
# Playback now carries the real shared recording reference. Link the current
# core manifest rather than compiling isolated copies of core source files.
while IFS= read -r object; do
    case "$object" in
        */HiDockCLI.build/*) continue ;;
    esac
    OBJECTS+=("$object")
done < "$BIN_PATH/hidock.product/Objects.LinkFileList"
swiftc -swift-version 5 -parse-as-library -I "$MODULES" \
    -I .build/checkouts/FluidAudio/Sources/FastClusterWrapper/include \
    -I .build/checkouts/FluidAudio/Sources/MachTaskSelfWrapper/include \
    -I Sources/CLibUSB/include \
    -L Vendor/libusb/lib -lusb-1.0 -lc++ \
    -framework IOKit -framework Security -framework Accelerate -framework CoreML \
    "${OBJECTS[@]}" \
    Sources/DockTape/State/PlaybackState.swift \
    Sources/DockTape/State/RecordingContentState.swift Tests/DockTapePlaybackTests.swift \
    -o "$OUTPUT"
"$OUTPUT"
