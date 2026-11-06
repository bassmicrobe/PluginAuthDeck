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
    fifo = root / "request.fifo"
    os.mkfifo(fifo)
    fifo_link = root / "request-link.json"
    fifo_link.symlink_to(fifo)
    for special_request in (fifo, fifo_link):
        assert invoke(["--request", str(special_request)]) == 2
        assert not (root / "status.json").exists()
    request = root / "request.json"
    request.write_text("x" * 65537)
    assert invoke(["--request", str(request)]) == 2
    assert not (root / "status.json").exists()

    # The kernel's real parent is this Python process; a forged saved PID must
    # fail, without opening a GUI or reaching any plug-in scanner.
    unicode_name = "日本語 🎛️ [quoted]"
    request.write_text(json.dumps({"name": unicode_name, "parentPID": 1,
                                   "format": "VST3", "identifier": "/nonexistent.vst3"},
                                  ensure_ascii=False), encoding="utf-8")
    assert invoke(["--request", str(request)]) == 1
    status = json.loads((root / "status.json").read_text())
    assert status["state"] == "closed", status
    assert status["error"] == "Invalid launch request", status
    assert status["name"] == unicode_name, status
    assert status["classes"] == [], status
    assert not (root / "heartbeat.json").exists()

    (root / "status.json").unlink()
    request.write_text("{invalid json")
    assert invoke(["--request", str(request)]) == 1
    status = json.loads((root / "status.json").read_text())
    assert status["state"] == "closed" and status["error"] == "Invalid launch request"

    # Size alone does not bound parser recursion. Reject deep JSON and malformed
    # text before the JUCE parser, foreground activation, or plug-in loading.
    for payload in (b'[' * 30000 + b'0' + b']' * 30000,
                    b'{"name":"' + b'\xf0\x80\x80\x80' * 16 + b'trailing"}',
                    b'{"name":"\x80trailing"}', b'{}\0[]'):
        (root / "status.json").unlink()
        request.write_bytes(payload)
        assert invoke(["--request", str(request)]) == 1
        status = json.loads((root / "status.json").read_text())
        assert status["state"] == "closed" and status["error"] == "Invalid launch request", status
        assert status["classes"] == [] and not (root / "heartbeat.json").exists()

print("PASS: 12 pre-UI rejection cases; error retained after closed; no heartbeat or plug-in load")
