#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
BIN_PATH="$(swift build --show-bin-path)"
python3 Tests/CLIIntegrationTests.py "$BIN_PATH/hidock"
