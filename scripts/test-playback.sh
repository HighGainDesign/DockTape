#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

swift build
MODULES="$(swift build --show-bin-path)/Modules"
OUTPUT=".build/release-validation/playback-tests"
mkdir -p "$(dirname "$OUTPUT")"
swiftc -swift-version 5 -parse-as-library -I "$MODULES" \
    Sources/DockTape/State/PlaybackState.swift Tests/DockTapePlaybackTests.swift \
    -o "$OUTPUT"
"$OUTPUT"
