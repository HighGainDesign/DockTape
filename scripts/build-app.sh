#!/bin/bash
set -euo pipefail

# Build DockTape.app via xcodegen + xcodebuild
# Usage: ./scripts/build-app.sh [--install]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

INSTALL=false
CONFIG="Release"
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=true ;;
        Debug|Release) CONFIG="$arg" ;;
    esac
done
DERIVED_DATA=".build/xcode"
BUILD_LOG=".build/release-validation/app-${CONFIG}-build.log"
mkdir -p "$(dirname "$BUILD_LOG")"

# Regenerate Xcode project from project.yml
echo "Generating Xcode project..."
xcodegen generate --quiet

# Build
echo "Building DockTape.app ($CONFIG)..."
xcodebuild \
    -project DockTape.xcodeproj \
    -scheme DockTape \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED_DATA" \
    build 2>&1 | tee "$BUILD_LOG"

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIG/DockTape.app"

if [ ! -d "$APP_PATH" ]; then
    echo "Build failed — no .app bundle found"
    exit 1
fi

echo ""
echo "Built: $APP_PATH"
echo "Size:  $(du -sh "$APP_PATH" | cut -f1)"

# Install to /Applications if --install flag
if [ "$INSTALL" = true ]; then
    echo ""
    echo "Installing to /Applications..."
    rm -rf /Applications/DockTape.app
    cp -R "$APP_PATH" /Applications/DockTape.app
    echo "Installed: /Applications/DockTape.app"
fi
