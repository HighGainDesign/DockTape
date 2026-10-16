#!/bin/bash
set -euo pipefail

# Verify the real device-only Keychain factory from a provisioned, signed host.
# Usage: ./scripts/test-shared-identity.sh /path/to/signed/DockTape.app
# Creates/reads the app's installation nonce; never opens a recording library.
# No secrets are printed. Local probe identity files stay in ignored .build.
cd "$(dirname "$0")/.."
HOST_APP="${1:?Pass a signed DockTape.app with its provisioning profile}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Anand Mandapati (UX8BPNLPX5)}"
PROBE_ROOT="$PWD/.build/shared-library/native-identity"
PROBE_APP="$PROBE_ROOT/DockTapeIdentityProbe.app"
PROFILE="$HOST_APP/Contents/embedded.provisionprofile"
[[ -f "$PROFILE" ]] || { echo 'Signed host has no embedded profile.' >&2; exit 1; }
codesign --verify --strict "$HOST_APP"
mkdir -p "$PROBE_APP/Contents/MacOS"
codesign -d --xml --entitlements - "$HOST_APP" > "$PROBE_ROOT/host-entitlements.plist"
cp "$PROFILE" "$PROBE_APP/Contents/embedded.provisionprofile"
python3 - "$HOST_APP" "$PROBE_APP" "$PROBE_ROOT" <<'PY'
import pathlib,plistlib,sys
host,app,root=map(pathlib.Path,sys.argv[1:])
info=plistlib.loads((host/'Contents/Info.plist').read_bytes())
entitlements=plistlib.loads((root/'host-entitlements.plist').read_bytes())
app_id=entitlements['com.apple.application-identifier']
groups=entitlements.get('keychain-access-groups',[])
assert app_id in groups, 'Host must explicitly authorize its device-only shared-library Keychain group'
allowed={k:entitlements[k] for k in ['com.apple.application-identifier','com.apple.developer.team-identifier','keychain-access-groups']}
(root/'entitlements.plist').write_bytes(plistlib.dumps(allowed))
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':info['CFBundleIdentifier'],'CFBundleExecutable':'identity-probe','CFBundlePackageType':'APPL','CFBundleName':'DockTape Identity Probe','CFBundleVersion':'1','LSUIElement':True}))
PY
swift build
BIN_PATH="$(swift build --show-bin-path)"
OBJECTS=()
while IFS= read -r object; do
    case "$object" in */HiDockCLI.build/*) continue;; esac
    OBJECTS+=("$object")
done < "$BIN_PATH/hidock.product/Objects.LinkFileList"
swiftc -swift-version 5 -parse-as-library -I "$BIN_PATH/Modules" \
    -I .build/checkouts/FluidAudio/Sources/FastClusterWrapper/include \
    -I .build/checkouts/FluidAudio/Sources/MachTaskSelfWrapper/include \
    -I Sources/CLibUSB/include -L Vendor/libusb/lib -lusb-1.0 -lc++ \
    -framework IOKit -framework Security -framework LocalAuthentication -framework Accelerate -framework CoreML \
    "${OBJECTS[@]}" Tests/SharedIdentityProbe.swift -o "$PROBE_APP/Contents/MacOS/identity-probe"
# Unprovisioned tools fail closed instead of creating a fallback writer.
UNSIGNED_STATE="$(mktemp -d "$PROBE_ROOT/unsigned-state.XXXXXX")"
if "$PROBE_APP/Contents/MacOS/identity-probe" "$UNSIGNED_STATE" \
    > "$PROBE_ROOT/unsigned-result.json" 2> "$PROBE_ROOT/unsigned-error.log"; then
    echo 'Unprovisioned host unexpectedly acquired a shared-library identity.' >&2
    exit 1
fi
[[ ! -e "$UNSIGNED_STATE/writer.json" ]] || { echo 'Failed host wrote a writer identity.' >&2; exit 1; }
python3 - "$PROBE_ROOT/unsigned-error.log" <<'IDENTITY_ASSERT'
import pathlib,sys
assert 'keychain(' in pathlib.Path(sys.argv[1]).read_text(), 'Unsigned host must fail at Keychain authorization'
IDENTITY_ASSERT
rmdir "$UNSIGNED_STATE"
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
    --entitlements "$PROBE_ROOT/entitlements.plist" "$PROBE_APP"
codesign --verify --strict --verbose "$PROBE_APP"
"$PROBE_APP/Contents/MacOS/identity-probe" "$PROBE_ROOT/local-state" > "$PROBE_ROOT/first.json"
"$PROBE_APP/Contents/MacOS/identity-probe" "$PROBE_ROOT/local-state" > "$PROBE_ROOT/second.json"
python3 - "$PROBE_ROOT" <<'PY'
import pathlib,json,sys
root=pathlib.Path(sys.argv[1])
assert json.loads((root/'first.json').read_text())==json.loads((root/'second.json').read_text())
print('Unsigned host fails closed; signed native device-only Keychain identity is stable across process launches; no library enabled.')
PY
