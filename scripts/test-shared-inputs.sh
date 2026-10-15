#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
BIN_PATH="$(swift build --show-bin-path)"
OUTPUT=".build/shared-library/process-fixture"
mkdir -p "$(dirname "$OUTPUT")"
OBJECTS=()
while IFS= read -r object; do
    case "$object" in
        */HiDockCLI.build/*|*/HiDockKitUSB.build/*) continue ;;
    esac
    OBJECTS+=("$object")
done < "$BIN_PATH/hidock.product/Objects.LinkFileList"
swiftc -swift-version 5 -parse-as-library -I "$BIN_PATH/Modules" \
    -I .build/checkouts/FluidAudio/Sources/FastClusterWrapper/include \
    -I .build/checkouts/FluidAudio/Sources/MachTaskSelfWrapper/include \
    -lc++ -framework Security -framework Accelerate -framework CoreML \
    "${OBJECTS[@]}" Tests/SharedLibraryProcessFixture.swift -o "$OUTPUT"
python3 - "$OUTPUT" <<'PYTEST'
import pathlib, subprocess, sys, tempfile
fixture=str(pathlib.Path(sys.argv[1]).resolve())
writer='00000000-0000-0000-0000-000000000001'
unused='10000000-0000-0000-0000-000000000001'
failures=[]
for kind in ['import','repair','replacement','merge']:
    with tempfile.TemporaryDirectory(prefix='docktape-accepted-input-') as temporary:
        parent=pathlib.Path(temporary); root=parent/'library'; root.mkdir(); local=parent/'local'
        originals={}
        if kind=='merge':
            for name,fill in [('One.mp3',1),('Two.mp3',2)]:
                data=bytes([0xff,0xfb,0x90,0x64])+bytes([fill])*413
                originals[name]=data; (root/name).write_bytes(data)
        if kind in ['repair','replacement']:
            fill=3 if kind=='repair' else 4
            (root/'Accepted.mp3').write_bytes(bytes([0xff,0xfb,0x90,0x64])+bytes([fill])*413)
        args=[str(root),writer,unused,str(local)]
        seeded=subprocess.run([fixture,'accept-seed',*args],capture_output=True,text=True,timeout=15)
        assert seeded.returncode==0,(seeded.returncode,seeded.stdout,seeded.stderr)
        if kind=='repair': (root/'Accepted.mp3').write_bytes(b'corrupt local audio')
        previous=(root/'Accepted.mp3').read_bytes() if (root/'Accepted.mp3').exists() else None
        command='merge' if kind=='merge' else 'import'
        crash=subprocess.run([fixture,'accept-'+command+'-crash',*args],capture_output=True,text=True,timeout=15)
        assert crash.returncode==74,(kind,crash.returncode,crash.stdout,crash.stderr)
        if previous is None: assert not (root/'Accepted.mp3').exists()
        else: assert (root/'Accepted.mp3').read_bytes()==previous
        staged=list((root/'.docktape/staging').rglob('*.mp3'))
        assert len(staged)==1,(kind,staged)
        expected=staged[0].read_bytes()
        assert not list((local/'Operations').rglob('*.json')), 'Process must exit before local receipt creation'
        if kind=='merge':
            assert expected[-834:]==originals['One.mp3']+originals['Two.mp3']
            (root/'One.mp3').write_bytes(b'later input change')
        resumed=subprocess.run([fixture,'accept-resume',*args],capture_output=True,text=True,timeout=15)
        if resumed.returncode!=0 or resumed.stdout.strip()!='complete':
            failures.append((kind,resumed.returncode,resumed.stdout,resumed.stderr)); continue
        assert (root/'Accepted.mp3').read_bytes()==expected
        assert not list((root/'.docktape/staging').rglob('*.mp3'))
assert not failures, failures
print('Actual post-accept/pre-receipt process exits recovered import, repair, replacement and merge without new input.')
PYTEST
