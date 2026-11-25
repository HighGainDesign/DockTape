# © 2026 High Gain Design. All rights reserved.
"""Actual CLI boundary checks; disposable legacy bytes, no hardware/models/Keychain."""
import pathlib, subprocess, sys, tempfile
binary = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="docktape-cli-") as directory:
    root = pathlib.Path(directory) / "chosen library"
    root.mkdir()
    (root / "Chosen.mp3").write_bytes(b"synthetic fixture")
    def run(*args):
        return subprocess.run([str(binary), *args], capture_output=True, text=True, timeout=30)
    selected = run("recordings", "--library", str(root))
    assert selected.returncode == 0 and "Chosen.mp3" in selected.stdout, selected
    assert not (root / ".docktape").exists(), "Reading does not enable shared format"
    status = run("shared", "status", "--library", str(root))
    assert status.returncode == 0 and "Legacy library" in status.stdout, status
    missing = run("recordings", "--library")
    assert missing.returncode != 0 and "--library" in missing.stderr, missing
    repeated = run("recordings", "--library", str(root), "--library", str(root))
    assert repeated.returncode != 0, repeated
    unknown = run("unrecognized-command")
    assert unknown.returncode != 0, unknown
    refused = run("shared", "request-access", "--library", str(root))
    assert refused.returncode != 0 and not (root / ".docktape").exists(), refused
    help_result = run("help")
    assert "--library" in help_result.stdout and "shared" in help_result.stdout, help_result
print("7 actual CLI root/legacy/setup/error checks passed; no hardware, model or Keychain access.")
