#!/bin/bash
set -euo pipefail

# Build, sign, notarize, and package DockTape.app for distribution
# Usage: ./scripts/release.sh
#
# Prerequisites:
#   - Developer ID Application certificate installed
#   - App-specific password stored: xcrun notarytool store-credentials "Notarize"
#   - xcodegen installed (brew install xcodegen)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

DERIVED_DATA=".build/xcode"
CONFIG="Release"
SIGNING_IDENTITY="Developer ID Application: Anand Mandapati (UX8BPNLPX5)"
TEAM_ID="UX8BPNLPX5"
BUNDLE_ID="design.highgain.docktape"
VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | sed 's/.*: *"\(.*\)"/\1/')
DMG_NAME="DockTape-${VERSION}.dmg"
RELEASE_DIR="$PROJECT_DIR/.build/release"

echo "=== DockTape Release Build v${VERSION} ==="
echo ""

# Step 1: Generate Xcode project
echo "1/6 Generating Xcode project..."
xcodegen generate --quiet

# Step 2: Clean build with Release configuration
echo "2/6 Building (Release, signed)..."
xcodebuild \
    -project DockTape.xcodeproj \
    -scheme DockTape \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Manual \
    clean build 2>&1 | tail -3

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIG/DockTape.app"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: Build failed — no .app bundle found"
    exit 1
fi

# Clear Dropbox extended attributes that break codesign
xattr -cr "$APP_PATH" 2>/dev/null || true

# Step 3: Re-sign (belt and suspenders after xattr cleanup)
echo "3/6 Signing..."
codesign --force --deep --options runtime \
    --sign "$SIGNING_IDENTITY" \
    --entitlements Sources/DockTape/Resources/DockTape.entitlements \
    "$APP_PATH"

codesign --verify --verbose "$APP_PATH"
echo "   Signed OK"

# Step 4: Create DMG with installer layout (app left, Applications right)
echo "4/6 Packaging DMG..."
mkdir -p "$RELEASE_DIR"
DMG_PATH="$RELEASE_DIR/$DMG_NAME"
rm -f "$DMG_PATH"

create-dmg \
    --volname "DockTape" \
    --volicon "Sources/DockTape/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "DockTape.app" 150 185 \
    --app-drop-link 450 185 \
    --codesign "$SIGNING_IDENTITY" \
    --no-internet-enable \
    "$DMG_PATH" \
    "$APP_PATH" \
    || true  # create-dmg returns non-zero if background image is missing, but DMG is still created
echo "   DMG: $DMG_PATH"

# Step 5: Notarize
echo "5/6 Notarizing (this may take a few minutes)..."
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "Notarize" \
    --wait

# Step 6: Staple the notarization ticket
echo "6/6 Stapling..."
xcrun stapler staple "$DMG_PATH"

echo ""
echo "=== Release Complete ==="
echo "DMG: $DMG_PATH"
echo "Size: $(du -sh "$DMG_PATH" | cut -f1)"
echo ""
echo "Next steps:"
echo "  1. Test: open '$DMG_PATH' and drag to Applications"
echo "  2. Upload to GitHub: gh release create v${VERSION} '$DMG_PATH' --title 'DockTape v${VERSION}' --notes-file CHANGELOG.md"
