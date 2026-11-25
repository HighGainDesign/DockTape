# © 2026 High Gain Design. All rights reserved.
"""Run only with a provisioned, signed CLI/AppState host in a user login context."""
import json, pathlib, plistlib, shutil, subprocess, sys, tempfile, uuid
cli, probe = [pathlib.Path(arg).resolve() for arg in sys.argv[1:3]]
cli_bundle = cli.parents[2]
app = cli_bundle.parents[2]
app_info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
cli_info = plistlib.loads((cli_bundle / "Contents/Info.plist").read_bytes())
for key in ["CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString"]:
    assert app_info[key] == cli_info[key], key
assert (cli_bundle / "Contents/embedded.provisionprofile").read_bytes() == (app / "Contents/embedded.provisionprofile").read_bytes()
with tempfile.TemporaryDirectory(prefix="docktape-native-identity-") as directory:
    root = pathlib.Path(directory) / "library"
    root.mkdir()
    audio = b"synthetic fixture"
    (root / "A.mp3").write_bytes(audio)
    library = None
    def run(binary, *args):
        result = subprocess.run([str(binary), *args], capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
        return result
    try:
        run(cli, "shared", "enable", "--library", str(root))
        manifest = json.loads((root / ".docktape/format.json").read_text())
        library = str(uuid.UUID(manifest["libraryID"])).upper()
        founder = str(uuid.UUID(manifest["founder"]))
        status = run(cli, "shared", "status", "--library", str(root))
        assert "Access: ready" in status.stdout, status
        linked = pathlib.Path(directory) / "hidock"
        linked.symlink_to(cli)
        assert "Access: ready" in run(linked, "shared", "status", "--library", str(root)).stdout
        run(probe, str(root), founder)
        assert "Access: ready" in run(cli, "shared", "status", "--library", str(root)).stdout
        recordings = run(cli, "recordings", "--library", str(root))
        assert "A.mp3" in recordings.stdout
        assert (root / "A.mp3").read_bytes() == audio
    finally:
        # Only this disposable library's local witnesses; preserve installation
        # identity/Keychain nonce and every other library's state.
        if library:
            witness = pathlib.Path.home() / "Library/Application Support/DockTape/SharedLibraries/Witnesses"
            for parent in [witness, witness / "Gates", witness / "Jobs", witness / "Operations"]:
                owned = parent / library
                if owned.exists(): shutil.rmtree(owned)
print("Native signed CLI/restart/symlink/AppState identity and shared edit checks passed; synthetic fixture only.")
