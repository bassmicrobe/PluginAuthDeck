#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Validate pre-UI rejection and bounded native OCR pipes; loads no plug-in.

Usage: python3 test_host_requests.py /absolute/path/to/AuthPluginHost
Requests reject before window creation; the valid OCR fixture has no window.
"""
import base64
import json
import os
from pathlib import Path
import subprocess
import struct
import sys
import tempfile
import time
import zlib

helper = Path(sys.argv[1]).resolve()
assert helper.is_file(), helper


def invoke(arguments):
    completed = subprocess.run([str(helper), *arguments], stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                               timeout=10)
    return completed.returncode


def synthetic_png(width=32, height=32, bit_depth=8):
    """Create uniform white fixture pixels entirely in memory, without AppKit."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    header = struct.pack(">IIBBBBB", width, height, bit_depth, 2, 0, 0, 0)
    rows = (b"\0" + b"\xff\xff\xff" * width) * height
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def worker_payload(pixels, **changes):
    # macOS libc++ steady_clock uses MONOTONIC_RAW. Python's monotonic clock
    # can have a different origin; protocol capture timestamps must match C++.
    header = {"version": 1, "product": "Synthetic Blank Fixture", "pngBytes": len(pixels),
              "sampledAtMilliseconds": time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW) / 1e6}
    header.update(changes)
    return json.dumps(header, separators=(",", ":"), allow_nan=False).encode() + b"\n" + pixels


def check_native_warmup(root):
    # Prepare Vision once with the worker's own fixed synthetic image before
    # exercising its unchanged 2.5-second per-image budget. Keep stdin open and
    # empty: warmup must not consume arbitrary image input or load a plug-in.
    print("Preparing native OCR with the fixed synthetic fixture (maximum 60 seconds)…", flush=True)
    before = set(root.iterdir())
    started = time.monotonic()
    process = subprocess.Popen(["/usr/bin/arch", "-arm64", str(helper), "--ocr-warmup", str(os.getpid())],
                               cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        assert process.wait(timeout=75) == 0, "native OCR warmup failed"
        assert time.monotonic() - started < 65, "warmup exceeded its 60-second bound plus startup allowance"
        output = process.stdout.read()
        assert len(output) <= 4096, "warmup output exceeded protocol bound"
        response = json.loads(output)
        assert set(response) == {"version", "ready"}, "unexpected warmup response fields"
        assert type(response["version"]) is int and response["version"] == 1, "invalid warmup version"
        assert response["ready"] is True, "warmup did not confirm model readiness"
        assert set(root.iterdir()) == before, "warmup created session/image files"
        assert not (root / "status.json").exists() and not (root / "heartbeat.json").exists()
        print("PASS: synthetic native OCR warmup; fixed ready response; no input or session files", flush=True)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=2)
        process.stdin.close()
        process.stdout.close()


def check_worker_protocol(root, name, payload, expected_code, keep_input_open=False):
    # Force native execution even if the test runner itself uses Rosetta. arch
    # replaces itself, preserving the real Python parent relationship.
    before = set(root.iterdir())
    started = time.monotonic()
    process = subprocess.Popen(["/usr/bin/arch", "-arm64", str(helper), "--ocr-worker", str(os.getpid())],
                               cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        try:
            if payload:
                process.stdin.write(payload)
                process.stdin.flush()
            if not keep_input_open:
                process.stdin.close()
        except BrokenPipeError:
            pass  # Early rejection may close the pipe before our write finishes.
        code = process.wait(timeout=6)
        elapsed = time.monotonic() - started
        output = process.stdout.read()
        assert code == expected_code, (name, code, expected_code)
        assert elapsed < 6, (name, "worker exceeded the outer test bound")
        if keep_input_open and expected_code == 74:
            assert 2.0 <= elapsed <= 5.0, (name, "worker did not enforce its 2.5-second deadline", elapsed)
        assert set(root.iterdir()) == before, (name, "worker created files")
        assert not (root / "status.json").exists() and not (root / "heartbeat.json").exists(), name
        if expected_code == 0:
            assert len(output) <= 4096, (name, "worker response exceeded protocol bound")
            response = json.loads(output)
            assert set(response) == {"version", "rule", "diagnostic", "staticTextNodes"}, name
            assert type(response["version"]) is int and response["version"] == 1, name
            assert response["rule"] == "", (name, "blank synthetic pixels cannot prove activation status")
            assert response["diagnostic"] in {"ocr_no_supported_status", "ocr_no_text", "ocr_image_unavailable",
                "ocr_time_budget_exceeded", "ocr_recognition_failed", "ocr_recognition_exception", "ocr_text_limit"}, name
            assert type(response["staticTextNodes"]) is int and 0 <= response["staticTextNodes"] <= 256, name
        else:
            assert output == b"", (name, "invalid input produced protocol output")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=2)
        try:
            process.stdin.close()
        except BrokenPipeError:
            pass
        process.stdout.close()


with tempfile.TemporaryDirectory(prefix="plugin-auth-host-input-") as directory:
    root = Path(directory)
    check_native_warmup(root)
    # Keep stdin open and send nothing. Malformed/fake-parent worker requests
    # must reject before waiting for a protocol header, creating any files, or
    # entering a plug-in host session. Only the retained test child is signalled.
    invalid_worker_arguments = [[], ["1"], ["0"], ["-1"], ["+2"], ["02"], [" 2"], ["2 "],
                                ["2junk"], ["2.0"], ["2e3"], ["2147483648"],
                                ["999999999999999999999999"], ["１２３"],
                                [str(os.getpid()) + "junk"], [str(os.getpid()), "extra"],
                                [str(os.getpid() + 1)]]
    for mode in ("--ocr-worker", "--ocr-warmup"):
        for suffix in invalid_worker_arguments:
            process = subprocess.Popen([str(helper), mode, *suffix], cwd=root,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            try:
                assert process.wait(timeout=2) == 2, (mode, suffix)
                assert process.stdout.read() == b"", (mode, suffix)
                assert list(root.iterdir()) == [], (mode, suffix)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=2)
                process.stdin.close()
                process.stdout.close()

    # All data is fabricated. Never read images, screenshots, plug-ins, or user
    # licensing files. A stalled writer keeps its anonymous pipe open on purpose.
    check_worker_protocol(root, "empty open pipe", b"", 74, keep_input_open=True)
    check_worker_protocol(root, "incomplete open header", b'{"version":1', 74, keep_input_open=True)
    check_worker_protocol(root, "incomplete open PNG", worker_payload(b"\x89PNG", pngBytes=100), 74, keep_input_open=True)
    blank = synthetic_png()
    malformed_protocol = [
        ("oversize JSON header", lambda: b'{"padding":"' + b"x" * 4096 + b'"}\n'),
        ("malformed JSON", lambda: b"{invalid}\n"),
        ("non-object header", lambda: b"[]\n"),
        ("missing header fields", lambda: b'{"version":1}\n'),
        ("negative PNG count", lambda: worker_payload(blank, pngBytes=-1)),
        ("zero PNG count", lambda: worker_payload(blank, pngBytes=0)),
        ("oversize PNG count", lambda: worker_payload(blank, pngBytes=12 * 1024 * 1024 + 1)),
        ("fractional PNG count", lambda: worker_payload(blank, pngBytes=1.5)),
        ("string PNG count", lambda: worker_payload(blank, pngBytes="10")),
        ("boolean PNG count", lambda: worker_payload(blank, pngBytes=True)),
        ("boolean version", lambda: worker_payload(blank, version=True)),
        ("unsupported version", lambda: worker_payload(blank, version=2)),
        ("non-string product", lambda: worker_payload(blank, product=12)),
        ("oversize product", lambda: worker_payload(blank, product="x" * 1025)),
        ("boolean capture timestamp", lambda: worker_payload(blank, sampledAtMilliseconds=True)),
        ("invalid PNG", lambda: worker_payload(b"not a PNG image")),
        ("zero width PNG", lambda: worker_payload(synthetic_png(width=0))),
        ("oversize PNG dimension", lambda: worker_payload(synthetic_png(width=2049, height=1))),
        ("oversize PNG pixel count", lambda: worker_payload(synthetic_png(width=2000, height=1300))),
        ("invalid PNG bit depth", lambda: worker_payload(synthetic_png(bit_depth=3))),
        ("GIF instead of PNG", lambda: worker_payload(base64.b64decode("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))),
        ("truncated closed PNG", lambda: worker_payload(blank[:-10], pngBytes=len(blank))),
        ("surplus pipe bytes", lambda: worker_payload(blank) + b"unexpected"),
    ]
    for name, payload in malformed_protocol:
        check_worker_protocol(root, name, payload(), 2)
    check_worker_protocol(root, "valid synthetic blank PNG", worker_payload(blank), 0)
    print("PASS: 27 native OCR pipe cases; 3 stalled writers bounded; malformed images/headers rejected; fixed-key blank result; no files")
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

    for deadline in (34, 91, 35.5, "70", True):
        (root / "status.json").unlink()
        request.write_text(json.dumps({"name": "Invalid deadline fixture", "parentPID": os.getpid(),
                                       "mode": "scan", "scanDeadlineSeconds": deadline,
                                       "format": "VST3", "identifier": "/nonexistent.vst3"}))
        assert invoke(["--request", str(request)]) == 1
        status = json.loads((root / "status.json").read_text())
        assert status["state"] == "closed" and status["error"] == "Invalid scan deadline", status
        assert status["failureReason"] == "invalid_request" and status["lastActivePhase"] == "", status
        assert not (root / "heartbeat.json").exists()

    # Initialization may be disabled only with an explicit boolean, never a
    # truthy string/number or a malformed object interpreted as a default.
    for initialization in (None, 0, 1, "false", [], {}):
        (root / "status.json").unlink()
        request.write_text(json.dumps({"name": "Invalid initialization fixture", "parentPID": os.getpid(),
                                       "mode": "scan", "initializeProcessor": initialization,
                                       "format": "VST3", "identifier": "/nonexistent.vst3"}))
        assert invoke(["--request", str(request)]) == 1
        status = json.loads((root / "status.json").read_text())
        assert status["state"] == "closed" and status["error"] == "Invalid processor initialization option", status
        assert status["failureReason"] == "invalid_request" and status["lastActivePhase"] == "", status
        assert not (root / "heartbeat.json").exists()

print("PASS: 57 pre-UI rejection cases including 34 worker/warmup arguments with open stdin; no worker files or plug-in load")
print("PASS: 85 total cases (1 synthetic warmup, 27 OCR protocol, 57 pre-UI rejection)")
