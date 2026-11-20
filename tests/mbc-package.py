"""Focused bundled BLE payload checks; installs only into temporary prefixes."""
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

package = Path(sys.argv[1]).resolve()
legacy_package = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else None
metadata = json.loads((package / "module.json").read_text())
assert metadata.get("bleClient") == "macos-ble-control", "Package must declare its bundled BLE client"
for relative in ("mbc", "macos-ble-control", "source/mbc/MBCMain.swift", "source/mbc/MBCOptions.swift",
                 "source/mbc/Info.plist", "source/mbc/build.sh", "source/mbc/install.sh", "source/mbc/README.md",
                 "source/mbc/tests/test_mbc_cli.py"):
    assert (package / relative).is_file(), f"Missing bundled BLE payload: {relative}"
for binary in ("mbc", "macos-ble-control"):
    path = package / binary
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(path)], check=True)
    load_commands = subprocess.run(["/usr/bin/otool", "-l", str(path)], capture_output=True,
                                   text=True, check=True, timeout=10).stdout
    section = re.search(r"sectname __info_plist\s+segname __TEXT\s+addr\s+\S+\s+size\s+(0x[0-9a-fA-F]+)\s+offset\s+(\d+)",
                        load_commands)
    assert section, f"{binary} is missing the __TEXT,__info_plist section"
    size, offset = (int(section.group(1), 16), int(section.group(2)))
    info = plistlib.loads(path.read_bytes()[offset:offset + size])
    assert info.get("CFBundleIdentifier") == "com.copis.macos-ble-control.cli"
    purpose = info.get("NSBluetoothAlwaysUsageDescription")
    assert isinstance(purpose, str) and purpose.strip(), f"{binary} has no Bluetooth usage description"

with tempfile.TemporaryDirectory(prefix="mcc-mbc-package-") as tmp:
    root = Path(tmp)
    # Exclude the user's separately installed MBC, Rust and Swift from PATH.
    env = dict(os.environ, PATH="/usr/bin:/bin:/usr/sbin:/sbin",
               COPIS_DESKTOP_RUNTIME_DIR=str(root / "runtime"), MCC_CONFIG_DIR=str(root / "config"))

    def run(*args, ok=True):
        result = subprocess.run(list(map(str, args)), env=env, text=True, capture_output=True, timeout=60)
        assert result.returncode == 0 if ok else result.returncode != 0, (result.stdout, result.stderr)
        return result

    def preview(cli):
        result = run(cli, "--eb", "--dry-run", "--move", "52,54", "--click")
        assert json.loads(result.stdout) == {"device": "pilot-2", "commands": ["move 52 54", "click 52 54"]}

    preview(package / "mcc")
    assert "--move" in run(package / "mbc", "--help").stdout
    assert "--type" in run(package / "macos-ble-control", "--help").stdout
    prefix = root / "prefix with spaces"
    run("/bin/sh", package / "install.sh", "--prefix", prefix, "--package", package)
    stable = prefix / "Applications/MCC"
    assert (stable / "mbc").is_file() and (stable / "macos-ble-control").is_file()
    preview(prefix / "bin/mcc")

    broken = root / "incomplete"
    shutil.copytree(package, broken)
    (broken / "macos-ble-control").unlink()
    rejected_prefix = root / "rejected"
    result = run("/bin/sh", broken / "install.sh", "--prefix", rejected_prefix, "--package", broken, ok=False)
    assert "BLE" in result.stderr, result.stderr
    assert not rejected_prefix.exists(), "Incomplete BLE package must be rejected before installation"

    # The new installer must still accept an older, signed package without BLE metadata.
    if legacy_package:
        assert "bleClient" not in json.loads((legacy_package / "module.json").read_text())
        legacy_prefix = root / "legacy"
        run("/bin/sh", package / "install.sh", "--prefix", legacy_prefix, "--package", legacy_package)
        assert (legacy_prefix / "bin/mcc").is_symlink()
    assert not (root / "runtime").exists()
    assert not (root / "config").exists()
print("PASS: bundled BLE binaries/source/signatures, isolated preview/install, incomplete-payload rejection and legacy compatibility")
