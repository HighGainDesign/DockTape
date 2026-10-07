#!/bin/bash
set -euo pipefail

# Rebuild the existing vendored libusb version for DockTape's macOS 14 minimum.
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="1.0.29"
SHA256="5977fc950f8d1395ccea9bd48c06b3f808fd3c2c961b44b0c2e6e29fc3a70a85"
WORK_DIR="$PROJECT_DIR/.build/libusb-${VERSION}"
ARCHIVE="$WORK_DIR/libusb-${VERSION}.tar.bz2"
mkdir -p "$WORK_DIR"

curl --fail --location --retry 3 \
    "https://github.com/libusb/libusb/releases/download/v${VERSION}/libusb-${VERSION}.tar.bz2" \
    --output "$ARCHIVE"
printf '%s  %s\n' "$SHA256" "$ARCHIVE" | shasum -a 256 --check
tar -xjf "$ARCHIVE" -C "$WORK_DIR"
cd "$WORK_DIR/libusb-${VERSION}"
env MACOSX_DEPLOYMENT_TARGET=14.0 \
    CFLAGS="-O2 -arch arm64 -mmacosx-version-min=14.0" \
    LDFLAGS="-arch arm64 -mmacosx-version-min=14.0" \
    ./configure --disable-shared --enable-static --disable-tests-build --disable-examples-build
make -j "$(sysctl -n hw.ncpu)"
install -m 644 libusb/.libs/libusb-1.0.a "$PROJECT_DIR/Vendor/libusb/lib/libusb-1.0.a"
install -m 644 libusb/libusb.h "$PROJECT_DIR/Vendor/libusb/include/libusb.h"
install -m 644 COPYING "$PROJECT_DIR/Vendor/libusb/COPYING"
echo "Vendored libusb ${VERSION} rebuilt for arm64, macOS 14.0."
