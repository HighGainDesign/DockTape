#!/bin/bash
set -euo pipefail

[[ "${GITHUB_ACTIONS:-}" == "true" ]] || { echo "This cleanup is for a temporary GitHub runner." >&2; exit 2; }
KEYCHAIN_PATH="${CI_SIGNING_KEYCHAIN:-$RUNNER_TEMP/docktape-signing.keychain-db}"
if [[ -f "$KEYCHAIN_PATH" ]]; then
    security default-keychain -d user -s "$HOME/Library/Keychains/login.keychain-db"
    security delete-keychain "$KEYCHAIN_PATH"
fi
if [[ -n "${CI_PROFILE_UUID:-}" ]]; then
    rm -f "$HOME/Library/MobileDevice/Provisioning Profiles/$CI_PROFILE_UUID.provisionprofile" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$CI_PROFILE_UUID.provisionprofile"
fi
if [[ -n "${RUNNER_TEMP:-}" ]]; then
    rm -f "$RUNNER_TEMP/docktape-signing.p12" "$RUNNER_TEMP/docktape.provisionprofile" "$RUNNER_TEMP/docktape-profile.plist"
fi
