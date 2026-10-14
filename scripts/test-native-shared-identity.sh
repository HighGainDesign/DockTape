#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP_PATH="${1:?Pass a locally signed DockTape.app candidate}"
CLI_PATH="$APP_PATH/Contents/Helpers/DockTapeCLI.bundle/Contents/MacOS/hidock"
PROFILE="$APP_PATH/Contents/embedded.provisionprofile"
test -x "$CLI_PATH"
test -f "$PROFILE"
codesign --verify --deep --strict "$APP_PATH"
swift build
BIN_PATH="$(swift build --show-bin-path)"
PROBE=".build/shared-library/native-identity/IdentityProbe.app"
mkdir -p "$PROBE/Contents/MacOS"
python3 - "$APP_PATH/Contents/Info.plist" "$PROBE/Contents/Info.plist" <<'PLIST'
import plistlib, sys
from pathlib import Path
source = plistlib.loads(Path(sys.argv[1]).read_bytes())
properties = {key: source[key] for key in ['CFBundleIdentifier', 'CFBundleVersion', 'CFBundleShortVersionString']}
properties.update(CFBundleExecutable='IdentityProbe', CFBundlePackageType='APPL', LSBackgroundOnly=True)
Path(sys.argv[2]).write_bytes(plistlib.dumps(properties))
PLIST
cp "$PROFILE" "$PROBE/Contents/embedded.provisionprofile"
OBJECTS=()
while IFS= read -r object; do
    case "$object" in */HiDockCLI.build/*) continue ;; esac
    OBJECTS+=("$object")
done < "$BIN_PATH/hidock.product/Objects.LinkFileList"
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(find Sources/DockTape -name '*.swift' ! -name AppDelegate.swift)
swiftc -swift-version 5 -parse-as-library -I "$BIN_PATH/Modules" \
    -I Sources/CLibUSB/include \
    -I .build/checkouts/FluidAudio/Sources/FastClusterWrapper/include \
    -I .build/checkouts/FluidAudio/Sources/MachTaskSelfWrapper/include \
    -L Vendor/libusb/lib -lusb-1.0 -lc++ \
    -framework IOKit -framework Security -framework Accelerate -framework CoreML \
    "${OBJECTS[@]}" "${SOURCES[@]}" Tests/DockTapeNativeIdentityTests.swift -o "$PROBE/Contents/MacOS/IdentityProbe"
ENTITLEMENTS=".build/shared-library/native-identity/entitlements.plist"
codesign -d --xml --entitlements "$ENTITLEMENTS" "$APP_PATH"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Anand Mandapati (UX8BPNLPX5)}"
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS" "$PROBE"
codesign --verify --strict "$PROBE"
python3 Tests/NativeCLIIdentityTests.py "$CLI_PATH" "$PROBE/Contents/MacOS/IdentityProbe"
