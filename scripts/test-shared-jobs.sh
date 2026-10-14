#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
BIN_PATH="$(swift build --show-bin-path)"
OUTPUT=".build/shared-library/job-process-fixture"
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
import pathlib, subprocess, sys, tempfile, time
fixture=str(pathlib.Path(sys.argv[1]).resolve())
writer='00000000-0000-0000-0000-000000000001'
placeholder='10000000-0000-0000-0000-000000000001'
def run(mode,root,entity,local):
    result=subprocess.run([fixture,mode,str(root),writer,entity,str(local)],capture_output=True,text=True,timeout=10)
    if result.returncode: raise AssertionError(result.stderr)
    return result.stdout.strip()
for crash in [False,True]:
    with tempfile.TemporaryDirectory(prefix='docktape-active-job-') as directory:
        parent=pathlib.Path(directory); root=parent/'library'; root.mkdir(); local=parent/'local'
        audio=root/'Meeting.mp3'; audio.write_bytes(b'synthetic active process audio')
        entity=run('job-seed',root,placeholder,local)
        ready=parent/'ready'; release=parent/'release'
        holder=subprocess.Popen([fixture,'job-hold',str(root),writer,entity,str(local),str(ready),str(release)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            deadline=time.monotonic()+10
            while not ready.exists():
                if holder.poll() is not None: raise AssertionError(holder.communicate())
                if time.monotonic()>deadline: raise AssertionError('Holder did not acquire lease')
                time.sleep(.01)
            assert run('job-probe',root,entity,local)=='active'
            assert run('job-delete',root,entity,local)=='waiting'
            assert audio.read_bytes()==b'synthetic active process audio'
            if crash:
                holder.kill(); holder.communicate(timeout=5)
            else:
                release.write_text('release'); output,error=holder.communicate(timeout=5)
                assert holder.returncode==0,(output,error)
            assert run('job-probe',root,entity,local)=='idle'
            assert run('job-resume',root,entity,local)=='complete'
            assert not audio.exists()
            assert (parent/'disposed'/'Meeting.mp3').read_bytes()==b'synthetic active process audio'
        finally:
            if holder.poll() is None: holder.kill(); holder.communicate()
print('Two-process active-job checks passed: live veto, clean release, SIGKILL release and exact deferred disposal.')
PY
