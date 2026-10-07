#!/bin/bash
set -euo pipefail

[[ "${GITHUB_ACTIONS:-}" == "true" ]] || { echo "This setup is for a temporary GitHub runner." >&2; exit 2; }
for name in DEVELOPER_ID_CERTIFICATE_BASE64 DEVELOPER_ID_CERTIFICATE_PASSWORD PROVISIONING_PROFILE_BASE64 APPLE_ID APPLE_APP_SPECIFIC_PASSWORD APPLE_TEAM_ID; do
    [[ -n "${!name:-}" ]] || { echo "Missing repository secret: $name" >&2; exit 2; }
done
[[ "$APPLE_ID" == "dev@highgain.design" ]] || { echo "APPLE_ID must use the requested DockTape developer account." >&2; exit 2; }
[[ "$APPLE_TEAM_ID" == "UX8BPNLPX5" ]] || { echo "APPLE_TEAM_ID must match DockTape's signing team." >&2; exit 2; }

KEYCHAIN_PATH="$RUNNER_TEMP/docktape-signing.keychain-db"
KEYCHAIN_PASSWORD=$(openssl rand -base64 32)
echo "::add-mask::$KEYCHAIN_PASSWORD"
CERTIFICATE_PATH="$RUNNER_TEMP/docktape-signing.p12"
PROFILE_PATH="$RUNNER_TEMP/docktape.provisionprofile"
umask 077
printf 'CI_SIGNING_KEYCHAIN=%s\n' "$KEYCHAIN_PATH" >> "$GITHUB_ENV"
printf '%s' "$DEVELOPER_ID_CERTIFICATE_BASE64" | base64 --decode > "$CERTIFICATE_PATH"
printf '%s' "$PROVISIONING_PROFILE_BASE64" | base64 --decode > "$PROFILE_PATH"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$CERTIFICATE_PATH" -k "$KEYCHAIN_PATH" -P "$DEVELOPER_ID_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
security list-keychains -d user -s "$KEYCHAIN_PATH" "$HOME/Library/Keychains/login.keychain-db"
security default-keychain -d user -s "$KEYCHAIN_PATH"

security cms -D -i "$PROFILE_PATH" > "$RUNNER_TEMP/docktape-profile.plist"
PROFILE_UUID=$(/usr/libexec/PlistBuddy -c 'Print UUID' "$RUNNER_TEMP/docktape-profile.plist")
python3 - "$RUNNER_TEMP/docktape-profile.plist" <<'PY'
import datetime, plistlib, sys
from pathlib import Path
profile = plistlib.loads(Path(sys.argv[1]).read_bytes())
assert profile['Name'] == 'DockTape Developer ID', 'Unexpected provisioning profile'
assert profile['TeamIdentifier'] == ['UX8BPNLPX5'], 'Unexpected provisioning team'
assert profile['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Provisioning profile expired'
entitlements = profile['Entitlements']
assert entitlements['com.apple.application-identifier'] == 'UX8BPNLPX5.design.highgain.docktape', 'Unexpected app identifier'
assert 'iCloud.design.highgain.docktape' in entitlements['com.apple.developer.icloud-container-identifiers'], 'Missing iCloud container'
PY
printf 'CI_PROFILE_UUID=%s\n' "$PROFILE_UUID" >> "$GITHUB_ENV"
mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
cp "$PROFILE_PATH" "$HOME/Library/MobileDevice/Provisioning Profiles/$PROFILE_UUID.provisionprofile"
mkdir -p "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
cp "$PROFILE_PATH" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$PROFILE_UUID.provisionprofile"
xcrun notarytool store-credentials DockTape-CI --keychain "$KEYCHAIN_PATH" \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" >/dev/null

printf 'NOTARY_PROFILE=DockTape-CI\nNOTARY_KEYCHAIN_PATH=%s\n' "$KEYCHAIN_PATH" >> "$GITHUB_ENV"
rm -f "$CERTIFICATE_PATH" "$PROFILE_PATH" "$RUNNER_TEMP/docktape-profile.plist"
