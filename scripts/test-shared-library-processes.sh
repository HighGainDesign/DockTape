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
python3 - "$OUTPUT" <<'PY'
import json, pathlib, subprocess, sys, tempfile, time
fixture=str(pathlib.Path(sys.argv[1]).resolve())
writer='00000000-0000-0000-0000-000000000001'
entity='10000000-0000-0000-0000-000000000001'
# Each pair loads the same old state before either may commit. Separate OS
# processes must serialize counter allocation and retain independent fields.
for iteration in range(8):
    with tempfile.TemporaryDirectory(prefix='docktape-shared-process-') as temporary:
        root=pathlib.Path(temporary); gate=root/'release'; ready=[root/'one-ready',root/'two-ready']
        commands=[['write',str(root),writer,entity,'title','Alpha',str(ready[0]),str(gate)],
                  ['write',str(root),writer,entity,'folder','Calls',str(ready[1]),str(gate)]]
        children=[subprocess.Popen([fixture,*args],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) for args in commands]
        try:
            deadline=time.monotonic()+5
            while not all(path.exists() for path in ready):
                if any(child.poll() is not None for child in children):
                    raise RuntimeError('A fixture process exited before the common draft barrier')
                if time.monotonic()>deadline: raise TimeoutError('Processes did not reach the draft barrier')
                time.sleep(.01)
            gate.write_text('release')
            for child in children:
                stdout,stderr=child.communicate(timeout=10)
                assert child.returncode==0,(child.returncode,stdout,stderr)
            report=json.loads(subprocess.check_output([fixture,'read',str(root),writer,entity],text=True))
            assert report=={'title':'Alpha','folder':'Calls','sequence':2},report
        finally:
            for child in children:
                if child.poll() is None: child.terminate()
                child.communicate(timeout=5)
print('8 two-process shared-draft trials passed: both fields retained, owner sequence 2.')
# Same accepted entity/operation is projected by separate processes. One physical
# mutation occurs, and a process exit after move/before receipt completion replays.
for iteration in range(4):
    with tempfile.TemporaryDirectory(prefix='docktape-materialize-process-') as temporary:
        parent=pathlib.Path(temporary); root=parent/'library'; root.mkdir(); receipts=parent/'receipts'
        (root/'source.mp3').write_bytes(b'Synthetic process audio')
        subprocess.check_call([fixture,'seed-move',str(root),writer,entity])
        gate=parent/'release'; ready=[parent/'one-ready',parent/'two-ready']
        commands=[['move',str(root),writer,entity,str(receipts),str(path),str(gate)] for path in ready]
        children=[subprocess.Popen([fixture,*args],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) for args in commands]
        try:
            deadline=time.monotonic()+5
            while not all(path.exists() for path in ready):
                if any(child.poll() is not None for child in children): raise RuntimeError('Move fixture exited before gate')
                if time.monotonic()>deadline: raise TimeoutError('Move fixtures did not reach gate')
                time.sleep(.01)
            gate.write_text('release')
            for child in children:
                stdout,stderr=child.communicate(timeout=10)
                assert child.returncode==0 and stdout.strip()=='complete',(child.returncode,stdout,stderr)
            assert not (root/'source.mp3').exists()
            assert (root/'destination.mp3').read_bytes()==b'Synthetic process audio'
            assert (receipts/'mutation-count').read_text()=='mutation\n'
        finally:
            for child in children:
                if child.poll() is None: child.terminate()
                child.communicate(timeout=5)
with tempfile.TemporaryDirectory(prefix='docktape-materialize-crash-') as temporary:
    parent=pathlib.Path(temporary); root=parent/'library'; root.mkdir(); receipts=parent/'receipts'
    (root/'source.mp3').write_bytes(b'Synthetic process audio')
    subprocess.check_call([fixture,'seed-move',str(root),writer,entity])
    gate=parent/'release'; gate.write_text('release'); ready=parent/'ready'
    args=[str(root),writer,entity,str(receipts),str(ready),str(gate)]
    crash=subprocess.run([fixture,'move-crash',*args],capture_output=True,text=True,timeout=10)
    assert crash.returncode==73,(crash.returncode,crash.stdout,crash.stderr)
    assert (root/'destination.mp3').read_bytes()==b'Synthetic process audio'
    assert not (root/'source.mp3').exists()
    replay=subprocess.run([fixture,'move',*args],capture_output=True,text=True,timeout=10)
    assert replay.returncode==0 and replay.stdout.strip()=='complete',(replay.returncode,replay.stdout,replay.stderr)
    assert (receipts/'mutation-count').read_text()=='mutation\n'
print('4 two-process projection trials + actual exit/restart replay passed: one media file, one physical mutation.')

PY
