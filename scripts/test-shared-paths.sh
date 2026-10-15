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
import json, pathlib, subprocess, sys, tempfile
fixture=str(pathlib.Path(sys.argv[1]).resolve())
writer='00000000-0000-0000-0000-000000000001'
unused='10000000-0000-0000-0000-000000000001'
failures=[]
for kind in ['rename','move','delete','create','folder-rename','folder-delete','folder-delete-child','folder-delete-final']:
    with tempfile.TemporaryDirectory(prefix='docktape-accepted-path-') as temporary:
        parent=pathlib.Path(temporary); root=parent/'library'; (root/'Folder').mkdir(parents=True); local=parent/'local'
        audio=b'synthetic original'; nested=b'synthetic nested original'
        (root/'Meeting.mp3').write_bytes(audio); (root/'Folder/Nested.mp3').write_bytes(nested)
        args=[str(root),writer,unused,str(local)]
        seed=subprocess.run([fixture,'path-seed',*args],capture_output=True,text=True,timeout=15)
        assert seed.returncode==0,(kind,seed.returncode,seed.stdout,seed.stderr)
        ids=json.loads(subprocess.check_output([fixture,'path-ids',*args],text=True,timeout=15))
        record=next(item['id'] for item in ids if item['path']=='Meeting.mp3')
        folder=next(item['id'] for item in ids if item['kind']=='folder' and item['path']=='Folder')
        crash=subprocess.run([fixture,'path-'+kind+'-crash',*args],capture_output=True,text=True,timeout=15)
        assert crash.returncode==74,(kind,crash.returncode,crash.stdout,crash.stderr)
        if kind=='create':
            ids=json.loads(subprocess.check_output([fixture,'path-ids',*args],text=True,timeout=15))
            entity=next(item['id'] for item in ids if item['kind']=='folder' and item['path']=='New')
        else: entity=folder if kind.startswith('folder-') else record
        command='path-folder-delete-resume' if kind.startswith('folder-delete') else 'path-folder-resume' if kind in ['create','folder-rename'] else 'path-record-resume'
        resume_args=[str(root),writer,entity,str(local)]
        result=subprocess.run([fixture,command,*resume_args],capture_output=True,text=True,timeout=20)
        if result.returncode!=0 or result.stdout.strip()!='complete':
            failures.append((kind,result.returncode,result.stdout,result.stderr)); continue
        again=subprocess.run([fixture,command,*resume_args],capture_output=True,text=True,timeout=20)
        assert again.returncode==0 and again.stdout.strip()=='complete',(kind,again.returncode,again.stdout,again.stderr)
        if kind=='rename': assert (root/'Renamed.mp3').read_bytes()==audio and not (root/'Meeting.mp3').exists()
        elif kind=='move': assert (root/'Folder/Meeting.mp3').read_bytes()==audio and not (root/'Meeting.mp3').exists()
        elif kind=='delete': assert not (root/'Meeting.mp3').exists() and (parent/'disposed/Meeting.mp3').read_bytes()==audio
        elif kind=='create': assert (root/'New').is_dir()
        elif kind=='folder-rename': assert (root/'Renamed folder/Nested.mp3').read_bytes()==nested and not (root/'Folder').exists()
        else: assert not (root/'Folder').exists() and (parent/'disposed/Nested.mp3').read_bytes()==nested
assert not failures, failures
print('8 actual accepted-path process-exit scenarios and repeated replay passed; only fixture disposal used.')
PYTEST
