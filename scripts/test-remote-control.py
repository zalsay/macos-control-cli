#!/usr/bin/env python3
"""Offline CLI/host protocol smoke; never starts SSH, a daemon, or a GUI."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid


ROOT = Path(__file__).resolve().parent.parent
BIN = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / ".build/debug/Safarier"
PROFILE = "11111111-2222-3333-4444-555555555555"
OTHER = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"


def frame(value):
    payload = json.dumps(value, separators=(",", ":")).encode()
    return len(payload).to_bytes(4, "big") + payload


def request(operation, parameters=None):
    return {"version": 1, "requestID": str(uuid.uuid4()), "operation": operation,
            "parameters": parameters or {}}


def run_host(home, value):
    env = os.environ.copy()
    env["SAFARIER_HOME"] = str(home)
    result = subprocess.run([str(BIN), "host", "serve", "--profile", PROFILE],
                            input=frame(value), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            env=env, timeout=8, check=False)
    return result


def run_host_raw(home, payload):
    env = os.environ.copy()
    env["SAFARIER_HOME"] = str(home)
    result = subprocess.run([str(BIN), "host", "serve", "--profile", PROFILE],
                            input=len(payload).to_bytes(4, "big") + payload,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            env=env, timeout=8, check=False)
    return result


def decode(result):
    assert result.returncode == 0, result.stderr.decode(errors="replace")
    assert len(result.stdout) >= 5, result.stdout
    size = int.from_bytes(result.stdout[:4], "big")
    assert size <= 65_536 and len(result.stdout) == size + 4
    return json.loads(result.stdout[4:])


def main():
    assert BIN.is_file(), f"build first: {BIN}"
    with tempfile.TemporaryDirectory(prefix="sfa-remote-fixture-") as tmp:
        home = Path(tmp)
        profile_path = home / "profiles.json"
        profile_path.write_text(json.dumps({"version": 1, "records": [{
            "id": PROFILE, "name": "offline fixture", "mode": "persistent",
            "createdAt": 0, "allowsAgentAccess": True,
            "startURL": "https://example.invalid/",
        }]}))
        runtime = Path.home() / (".safarier-control-host-" + PROFILE)
        assert not runtime.exists(), "test profile runtime unexpectedly exists"

        denied = decode(run_host(home, request("connect", {"profile": OTHER})))
        assert denied["error"] == "PROFILE_NOT_ALLOWED"

        denied = decode(run_host(home, request("navigate", {
            "connection": str(uuid.uuid4()), "url": "file:///Users/host/private.txt"})))
        assert denied["error"] == "REMOTE_OPERATION_NOT_ALLOWED"

        denied = decode(run_host(home, request("select-file", {
            "connection": str(uuid.uuid4()), "paths": ["/Users/host/private.txt"]})))
        assert denied["error"] == "REMOTE_OPERATION_NOT_ALLOWED"

        denied = decode(run_host(home, request("daemonStop")))
        assert denied["error"] == "REMOTE_OPERATION_NOT_ALLOWED"

        denied = decode(run_host(home, request("authorizationRequest")))
        assert denied["error"] == "REMOTE_OPERATION_NOT_ALLOWED"
        denied = decode(run_host(home, request("authorizationStatus", {"requestID": str(uuid.uuid4())})))
        assert denied["error"] == "REMOTE_OPERATION_NOT_ALLOWED"

        malformed = [b"not-json", json.dumps({
            "version": 1, "requestID": 17, "operation": "authorizationRequest", "parameters": {}
        }).encode(), json.dumps({
            "version": 1, "requestID": str(uuid.uuid4()), "operation": "authorizationStatus",
            "parameters": {"requestID": 17}
        }).encode()]
        for payload in malformed:
            rejected = run_host_raw(home, payload)
            assert rejected.returncode != 0 and not rejected.stdout, rejected

        # A permitted request reaches the existing local control path, which
        # reports unavailable because this isolated fixture has no daemon.
        unavailable = decode(run_host(home, request("status")))
        assert unavailable["status"] == "error" and unavailable["error"] == "UNAVAILABLE"

        # Invalid host paths/options and SSH aliases are rejected before spawn.
        for option in ("--app", "--runtime"):
            result = subprocess.run([str(BIN), "--remote", "no-network", "control", option,
                                     "/tmp/attacker-controlled", "status"],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3)
            assert result.returncode == 64
        marker = home / "injected"
        result = subprocess.run([str(BIN), "--remote", f"bad alias;touch {marker}",
                                 "control", "status"], stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=3)
        assert result.returncode == 64
        assert not marker.exists()
        assert not runtime.exists(), "denied or unavailable request created a control runtime"
    print("remote-control offline smoke passed")


if __name__ == "__main__":
    main()
