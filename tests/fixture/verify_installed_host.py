#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# SPDX-License-Identifier: AGPL-3.0-only
"""Integration test of a selected host against an isolated synthetic VST3.

Only the retained test child is stopped. No real plug-in directory, license
ledger, production session directory, or production process is changed.
"""
import datetime
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--variant', choices=['normal', 'delayed', 'transient'], default='normal')
    parser.add_argument('--host', type=Path, help='AuthPluginHost executable; default: this checkout\'s dist bundle')
    parser.add_argument('--output', type=Path, help='JSON report path; default: this checkout\'s ignored results directory')
    args = parser.parse_args()
    fixture_root = Path(__file__).resolve().parent
    repository = fixture_root.parents[1]
    suffix = '' if args.variant == 'normal' else '-' + args.variant
    output = (args.output or repository / ('results/host-fixture' + suffix + '-verification.json')).expanduser().absolute()
    host = (args.host or repository / 'dist/Plugin Auth Desk.app/Contents/Helpers/AuthPluginHost.app/Contents/MacOS/AuthPluginHost').expanduser().absolute()
    plugin = fixture_root / 'build/AuthDetectionFixture_artefacts/Release/VST3/Plugin Auth Desk Fixture.vst3'
    product = 'Plugin Auth Desk Fixture'
    if not host.is_file() or not plugin.is_dir():
        raise RuntimeError('The selected host or the isolated fixture is missing. Build both first.')
    # The plug-in target is intentionally fixed. --host never selects a vendor
    # plug-in, and a symlinked replacement for the generated fixture is refused.
    if plugin.is_symlink() or not plugin.resolve().is_relative_to(fixture_root.resolve()):
        raise RuntimeError('Refusing a fixture outside this checkout.')
    with (plugin / 'Contents/Info.plist').open('rb') as stream:
        if plistlib.load(stream).get('CFBundleIdentifier') != 'local.plugin-auth-desk.test-fixture':
            raise RuntimeError('Refusing a bundle that is not the synthetic test fixture.')
    report = {
        'kind': 'synthetic-vst3-host-integration',
        'variant': args.variant,
        'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'host': str(host),
        'hostSHA256': hashlib.sha256(host.read_bytes()).hexdigest(),
        'fixture': str(plugin),
        'fixtureLabel': product + ' is not activated on this machine',
        'parentPID': os.getpid(),
        'deadlineSeconds': 40,
        'observationWindowSeconds': 30,
        'writesProductionState': False,
        'result': 'failed',
    }
    # Stage and sign only a copy inside this checkout's ignored results area.
    staging_root = repository / 'results/fixture-staging'
    staging_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='plugin-auth-host-fixture-', dir=staging_root) as temporary:
        directory = Path(temporary)
        staged_plugin = directory / 'Plugin Auth Desk Fixture.vst3'
        shutil.copytree(plugin, staged_plugin, copy_function=shutil.copyfile)
        staged_binary = staged_plugin / 'Contents/MacOS/Plugin Auth Desk Fixture'
        staged_binary.chmod(0o755)
        subprocess.run(['/usr/bin/xattr', '-cr', str(staged_plugin)], check=True, timeout=5)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', str(staged_plugin)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(staged_plugin)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        report['stagedFixture'] = str(staged_plugin)
        report['fixtureSignatureVerified'] = True
        report['stagedFixtureSHA256'] = hashlib.sha256(staged_binary.read_bytes()).hexdigest()
        request = {
            'name': product,
            'format': 'VST3',
            'identifier': str(staged_plugin),
            'path': str(staged_plugin),
            'parentPID': os.getpid(),
            'mode': 'scan',
        }
        request_path = directory / 'request.json'
        request_path.write_text(json.dumps(request), encoding='utf-8')
        environment = os.environ.copy()
        environment.pop('PAD_FIXTURE_DELAY_MS', None)
        environment.pop('PAD_FIXTURE_CLEAR_REQUEST', None)
        if args.variant != 'normal':
            environment['PAD_FIXTURE_DELAY_MS'] = '2200'
        clear_request = directory / 'clear-fixture-label.request'
        if args.variant == 'transient':
            environment['PAD_FIXTURE_CLEAR_REQUEST'] = str(clear_request)
        process = subprocess.Popen(
            ['/usr/bin/arch', '-arm64', str(host), '--request', str(request_path)],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            env=environment,
        )
        report['childPID'] = process.pid
        start = time.monotonic()
        timeline = []
        latest = {}
        sampled = False
        ready_seen = None
        candidate_seen = None
        cleanup = 'already-exited'
        try:
            while time.monotonic() - start < 30:
                if (os.environ.get('FIXTURE_SAMPLE') == '1' and not sampled
                        and time.monotonic() - start >= 5 and process.poll() is None):
                    sampled = True
                    sample_path = output.with_suffix('.sample.txt')
                    sample_path.parent.mkdir(parents=True, exist_ok=True)
                    sampled_process = subprocess.run(
                        ['/usr/bin/sample', str(process.pid), '1', '1', '-file', str(sample_path)],
                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        timeout=5,
                    )
                    report['samplePath'] = str(sample_path)
                    report['sampleExitCode'] = sampled_process.returncode
                try:
                    state = json.loads((directory / 'status.json').read_text(encoding='utf-8'))
                    if state != latest:
                        latest = state
                        timeline.append({
                            'elapsedSeconds': round(time.monotonic() - start, 3),
                            'state': state.get('state'),
                            'classID': state.get('classID'),
                            'licenseEvidence': state.get('licenseEvidence'),
                            'licenseCandidate': state.get('licenseCandidate'),
                        })
                    elapsed = time.monotonic() - start
                    if state.get('state') == 'ready' and ready_seen is None:
                        ready_seen = elapsed
                    candidate = state.get('licenseCandidate')
                    valid_identity = (state.get('pid') == process.pid and state.get('scanMode') is True
                                      and state.get('name') == product and bool(state.get('classID')))
                    if candidate is not None:
                        valid_candidate = (isinstance(candidate, dict)
                                           and set(candidate) == {'rule', 'observedAt'}
                                           and candidate.get('rule') == 'product_not_activated'
                                           and isinstance(candidate.get('observedAt'), (int, float))
                                           and math.isfinite(candidate['observedAt']) and candidate['observedAt'] > 0)
                        if not valid_candidate or not valid_identity or state.get('licenseEvidence'):
                            report['failureReason'] = 'invalid_or_confirmed_candidate_payload'
                            break
                        if candidate_seen is None:
                            candidate_seen = {'elapsedSeconds': elapsed, 'observedAt': candidate['observedAt']}
                            if args.variant == 'transient':
                                clear_request.write_text('clear only this synthetic label\n', encoding='utf-8')
                    evidence = state.get('licenseEvidence', {})
                    if args.variant == 'transient' and evidence:
                        report['failureReason'] = 'transient_candidate_was_confirmed'
                        break
                    if (args.variant == 'transient' and candidate_seen is not None and valid_identity
                            and candidate is None and not evidence and state.get('state') == 'ready'):
                        report['result'] = 'passed'
                        report['candidateClearedAtSeconds'] = elapsed
                        break
                    if (args.variant != 'transient' and valid_identity
                            and evidence.get('state') == 'needsActivation'
                            and evidence.get('rule') == 'product_not_activated'
                            and evidence.get('observations', 0) >= 2
                            and evidence.get('classID') == state.get('classID')
                            and evidence.get('name') == product):
                        if args.variant == 'delayed':
                            if (ready_seen is None or candidate_seen is None or elapsed - ready_seen < 4
                                    or evidence.get('observedAt') != candidate_seen['observedAt']
                                    or candidate is not None):
                                report['failureReason'] = 'delayed_candidate_transition_or_original_timestamp_missing'
                                break
                            report['evidenceAfterReadySeconds'] = round(elapsed - ready_seen, 3)
                        report['result'] = 'passed'
                        break
                except (FileNotFoundError, json.JSONDecodeError):
                    pass
                if process.poll() is not None:
                    break
                time.sleep(0.15)
        finally:
            report['elapsedSeconds'] = round(time.monotonic() - start, 3)
            report['timeline'] = timeline
            report['observedStatus'] = latest
            report['readySeenAtSeconds'] = ready_seen
            report['candidateFirstSeen'] = candidate_seen
            if process.poll() is None:
                (directory / 'quit.request').write_text('fixture verification finished\n', encoding='utf-8')
                cleanup = 'quit.request'
                try:
                    process.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    cleanup = 'terminate'
                    process.terminate()
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        cleanup = 'kill'
                        process.kill()
                        try:
                            process.wait(timeout=2)
                        except subprocess.TimeoutExpired:
                            report['cleanupWarning'] = 'The retained test child did not reap within the bounded wait.'
            report['cleanup'] = cleanup
            report['exitCode'] = process.returncode
            report['childExited'] = process.poll() is not None
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({key: report[key] for key in ['result', 'elapsedSeconds', 'childPID', 'cleanup', 'exitCode', 'childExited']}))
    print(str(output))
    return 0 if report['result'] == 'passed' and report['childExited'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
