#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build
BIN_PATH="$(swift build --show-bin-path)"
OUTPUT=".build/release-validation/import-state-tests"
mkdir -p "$(dirname "$OUTPUT")"
OBJECTS=()
# Use SwiftPM's current link manifest: globbing .o files can include stale
# objects left behind after a source rename in a long-lived checkout.
while IFS= read -r object; do
    case "$object" in
        */HiDockCLI.build/*) continue ;;
    esac
    OBJECTS+=("$object")
done < "$BIN_PATH/hidock.product/Objects.LinkFileList"
SOURCES=()
while IFS= read -r source; do
    SOURCES+=("$source")
done < <(find Sources/DockTape -name '*.swift' ! -name AppDelegate.swift)
swiftc -swift-version 5 -parse-as-library -I "$BIN_PATH/Modules" \
    -I Sources/CLibUSB/include \
    -I .build/checkouts/FluidAudio/Sources/FastClusterWrapper/include \
    -I .build/checkouts/FluidAudio/Sources/MachTaskSelfWrapper/include \
    -L Vendor/libusb/lib -lusb-1.0 -lc++ \
    -framework IOKit -framework Security -framework Accelerate -framework CoreML \
    "${OBJECTS[@]}" "${SOURCES[@]}" Tests/DockTapeImportTests.swift -o "$OUTPUT"
"$OUTPUT"
