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
PY
