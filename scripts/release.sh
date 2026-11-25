#!/bin/bash
set -euo pipefail

# Build, sign, notarize, and package DockTape.app for distribution
# Usage: ./scripts/release.sh (local verification; publish by pushing a version tag)
#
# Prerequisites:
#   - Developer ID Application certificate installed
#   - Credentials stored in NOTARY_PROFILE (default: Notarize)
#   - xcodegen installed (brew install xcodegen)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

DERIVED_DATA=".build/xcode"
CONFIG="Release"
SIGNING_IDENTITY="Developer ID Application: Anand Mandapati (UX8BPNLPX5)"
TEAM_ID="UX8BPNLPX5"
VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | sed 's/.*: *"\(.*\)"/\1/')
DMG_NAME="DockTape-${VERSION}.dmg"
RELEASE_DIR="$PROJECT_DIR/.build/release"
BUILD_LOG="$PROJECT_DIR/.build/release-validation/release-build.log"
APP_ENTITLEMENTS="$PROJECT_DIR/.build/release-validation/release-entitlements.plist"
NOTARY_PROFILE="${NOTARY_PROFILE:-Notarize}"
NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
if [[ -n "${NOTARY_KEYCHAIN_PATH:-}" ]]; then
    NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN_PATH")
fi
mkdir -p "$(dirname "$BUILD_LOG")"

notarize() {
    local artifact="$1" result="$2"
    xcrun notarytool submit "$artifact" "${NOTARY_ARGS[@]}" --wait --output-format json > "$result"
    python3 - "$result" <<'PY'
import json, sys
from pathlib import Path
result = json.loads(Path(sys.argv[1]).read_text())
print('Notarization:', result.get('status'), 'Submission:', result.get('id'))
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization was not accepted; see the submission log in Apple notarytool.')
PY
}

echo "=== DockTape Release Build v${VERSION} ==="
echo ""

# Step 1: Generate Xcode project
echo "1/8 Generating Xcode project..."
xcodegen generate --quiet

# Step 2: Clean build with Release configuration
echo "2/8 Building (Release, signed)..."
xcodebuild \
    -project DockTape.xcodeproj \
    -scheme DockTape \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Manual \
    clean build 2>&1 | tee "$BUILD_LOG"

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIG/DockTape.app"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: Build failed — no .app bundle found"
    exit 1
fi

# Clear Dropbox extended attributes that break codesign
xattr -cr "$APP_PATH" 2>/dev/null || true

# Step 3: Re-sign (belt and suspenders after xattr cleanup)
echo "3/8 Signing..."
# Preserve Xcode's resolved team/application/iCloud entitlements, without debug access.
codesign -d --xml --entitlements "$APP_ENTITLEMENTS" "$APP_PATH"
python3 - "$APP_ENTITLEMENTS" <<'PY'
import plistlib
import sys
from pathlib import Path
path = Path(sys.argv[1])
entitlements = plistlib.loads(path.read_bytes())
entitlements.pop("com.apple.security.get-task-allow", None)
path.write_bytes(plistlib.dumps(entitlements))
PY
CLI_BUNDLE="$APP_PATH/Contents/Helpers/DockTapeCLI.bundle"
test -x "$CLI_BUNDLE/Contents/MacOS/hidock"
test -f "$CLI_BUNDLE/Contents/embedded.provisionprofile"
python3 - "$APP_PATH/Contents/Info.plist" "$CLI_BUNDLE/Contents/Info.plist" <<'PLIST'
import plistlib, sys
from pathlib import Path
app, cli = [plistlib.loads(Path(path).read_bytes()) for path in sys.argv[1:]]
for key in ['CFBundleIdentifier', 'CFBundleVersion', 'CFBundleShortVersionString']:
    assert app[key] == cli[key], f'CLI {key} must match its provisioned host'
assert cli['CFBundleExecutable'] == 'hidock'
PLIST
codesign --force --options runtime --timestamp \
    --sign "$SIGNING_IDENTITY" \
    --entitlements "$APP_ENTITLEMENTS" \
    "$CLI_BUNDLE"
codesign --verify --strict --verbose "$CLI_BUNDLE"
codesign --force --deep --options runtime --timestamp \
    --sign "$SIGNING_IDENTITY" \
    --entitlements "$APP_ENTITLEMENTS" \
    "$APP_PATH"

codesign --verify --deep --strict --verbose "$APP_PATH"
echo "   Signed OK"

# Staple the app too, so the installed copy carries its offline trust ticket.
mkdir -p "$RELEASE_DIR"
echo "4/8 Notarizing app..."
APP_ZIP="$RELEASE_DIR/DockTape-${VERSION}-notarization.zip"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
notarize "$APP_ZIP" "$RELEASE_DIR/app-notarization.json"
rm -f "$APP_ZIP"
echo "5/8 Stapling app..."
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
codesign --verify --deep --strict --verbose "$APP_PATH"

# Headless packaging works both locally and on GitHub runners without Finder scripting.
echo "6/8 Packaging DMG..."
DMG_PATH="$RELEASE_DIR/$DMG_NAME"
rm -f "$DMG_PATH"

create-dmg \
    --skip-jenkins \
    --volname "DockTape" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "DockTape.app" 150 185 \
    --app-drop-link 450 185 \
    --codesign "$SIGNING_IDENTITY" \
    --no-internet-enable \
    "$DMG_PATH" \
    "$APP_PATH"

if [ ! -f "$DMG_PATH" ]; then
    echo "ERROR: DMG creation failed"
    exit 1
fi
echo "   DMG: $DMG_PATH"

# Step 5: Notarize
echo "7/8 Notarizing DMG..."
notarize "$DMG_PATH" "$RELEASE_DIR/dmg-notarization.json"

# Step 6: Staple the notarization ticket
echo "8/8 Stapling DMG..."
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
codesign --verify --strict --verbose "$DMG_PATH"
spctl --assess --type execute --verbose "$APP_PATH"
spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"
(cd "$RELEASE_DIR" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")

echo ""
echo "=== Release Complete ==="
echo "DMG: $DMG_PATH"
echo "Size: $(du -sh "$DMG_PATH" | cut -f1)"
echo ""
echo "Next steps:"
echo "  1. Test: open '$DMG_PATH' and drag to Applications"
echo "  2. Commit/push tested source, then push tag v${VERSION}. GitHub Actions creates the published DMG."
