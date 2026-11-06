#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Validate pre-UI helper rejection and error preservation; loads no plug-in.

Usage: python3 test_host_requests.py /absolute/path/to/AuthPluginHost
All test requests are rejected before makeForegroundProcess/window creation.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

helper = Path(sys.argv[1]).resolve()
assert helper.is_file(), helper


def invoke(arguments):
    completed = subprocess.run([str(helper), *arguments], stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                               timeout=10)
    return completed.returncode


with tempfile.TemporaryDirectory(prefix="plugin-auth-host-input-") as directory:
    root = Path(directory)
    assert invoke([]) == 2
    assert invoke(["--request", "relative.json"]) == 2
    assert invoke(["--request", str(root / "missing.json")]) == 2
    request = root / "request.json"
    request.write_text("x" * 65537)
    assert invoke(["--request", str(request)]) == 2
    assert not (root / "status.json").exists()

    # The kernel's real parent is this Python process; a forged saved PID must
    # fail, without opening a GUI or reaching any plug-in scanner.
    request.write_text(json.dumps({"name": "Rejected fixture", "parentPID": 1,
                                   "format": "VST3", "identifier": "/nonexistent.vst3"}))
    assert invoke(["--request", str(request)]) == 1
    status = json.loads((root / "status.json").read_text())
    assert status["state"] == "closed", status
    assert status["error"] == "Invalid launch request", status
    assert status["classes"] == [], status
    assert not (root / "heartbeat.json").exists()

    (root / "status.json").unlink()
    request.write_text("{invalid json")
    assert invoke(["--request", str(request)]) == 1
    status = json.loads((root / "status.json").read_text())
    assert status["state"] == "closed" and status["error"] == "Invalid launch request"

print("PASS: 6 pre-UI rejection cases; error retained after closed; no heartbeat or plug-in load")
