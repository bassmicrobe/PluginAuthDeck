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
import sys
import tempfile
import time


def prepare_ocr(host, directory):
    """Warm this exact helper using only its fixed synthetic image, never a plug-in."""
    started = time.monotonic()
    result = {'required': True, 'success': False, 'deadlineSeconds': 75}
    process = None
    try:
        process = subprocess.Popen(
            ['/usr/bin/arch', '-arm64', str(host), '--ocr-warmup', str(os.getpid())],
            cwd=directory, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        result['childPID'] = process.pid
        # Leave cleanup time inside the outer 75-second bound. The helper's own
        # watchdog is 60 seconds; this parent also owns and reaps only its child.
        try:
            response, _ = process.communicate(timeout=70)
        except subprocess.TimeoutExpired:
            result['failureReason'] = 'warmup_time_limit'
            process.kill()
            try:
                process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                result['failureReason'] = 'warmup_cleanup_timeout'
            response = b''
        if process.returncode == 0 and len(response) <= 4096:
            try:
                decoded = json.loads(response)
                result['success'] = (isinstance(decoded, dict) and set(decoded) == {'version', 'ready'}
                                     and type(decoded['version']) is int and decoded['version'] == 1
                                     and decoded['ready'] is True)
            except (ValueError, TypeError):
                pass
        if not result['success']:
            result.setdefault('failureReason', 'warmup_failed_or_invalid_response')
    except OSError:
        result['failureReason'] = 'warmup_launch_failed'
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            remaining = 75 - (time.monotonic() - started)
            try:
                process.wait(timeout=max(0.01, min(2.0, remaining)))
            except subprocess.TimeoutExpired:
                result['failureReason'] = 'warmup_cleanup_timeout'
        result['elapsedSeconds'] = round(time.monotonic() - started, 3)
        result['exitCode'] = process.returncode if process is not None else None
        result['childExited'] = process is None or process.poll() is not None
        if process is not None and process.stdout is not None:
            process.stdout.close()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--variant', choices=['normal', 'delayed', 'transient'], default='normal')
    parser.add_argument('--host', type=Path, help='AuthPluginHost executable; default: this checkout\'s dist bundle')
    parser.add_argument('--output', type=Path, help='JSON report path; default: this checkout\'s ignored results directory')
    parser.add_argument('--factory-metadata', action='store_true', help='Remove only the staged moduleinfo to exercise factory metadata without sibling instantiation')
    parser.add_argument('--ocr-only', action='store_true', help='Use painted fixture text with no accessibility text node')
    parser.add_argument('--editor-only', action='store_true', help='Exercise the explicit initialization opt-out without audio processing')
    parser.add_argument('--cancel-during-initialization', action='store_true', help='Request stop from a synthetic nested initialization loop; require no editor or ready state afterward')
    parser.add_argument('--architecture', choices=['arm64', 'x86_64'], default='arm64', help='Run the synthetic plug-in host natively or under Rosetta')
    args = parser.parse_args()
    if args.cancel_during_initialization and (args.editor_only or args.ocr_only or args.variant != 'normal'):
        parser.error('--cancel-during-initialization requires ordinary initialization and no OCR/delay variant')
    fixture_root = Path(__file__).resolve().parent
    repository = fixture_root.parents[1]
    suffix = '' if args.variant == 'normal' else '-' + args.variant
    if args.ocr_only:
        suffix += '-ocr'
    if args.architecture != 'arm64':
        suffix += '-' + args.architecture
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
        'factoryMetadata': args.factory_metadata,
        'ocrOnly': args.ocr_only,
        'editorOnly': args.editor_only,
        'cancelDuringInitialization': args.cancel_during_initialization,
        'architecture': args.architecture,
        'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'host': str(host),
        'hostSHA256': hashlib.sha256(host.read_bytes()).hexdigest(),
        'fixture': str(plugin),
        'fixtureLabel': product + ' is not activated on this machine',
        'parentPID': os.getpid(),
        'deadlineSeconds': 40,
        'observationWindowSeconds': 30,
        'writesProductionState': False,
        'warmup': {'required': args.ocr_only, 'success': None},
        'result': 'failed',
    }
    # Stage and sign only a copy inside this checkout's ignored results area.
    staging_root = repository / 'results/fixture-staging'
    staging_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='plugin-auth-host-fixture-', dir=staging_root) as temporary:
        directory = Path(temporary)
        if args.ocr_only:
            print('Preparing the selected native OCR helper before fixture observation…', flush=True)
            report['warmup'] = prepare_ocr(host, directory)
            if not report['warmup']['success']:
                report['failureReason'] = 'ocr_warmup_failed'
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
                print(json.dumps({'result': report['result'], 'warmup': report['warmup']}))
                print(str(output))
                return 1  # No fixture/plugin is loaded after failed preparation.
        staged_plugin = directory / 'Plugin Auth Desk Fixture.vst3'
        shutil.copytree(plugin, staged_plugin, copy_function=shutil.copy2)
        if args.factory_metadata:
            for relative in ('Contents/Resources/moduleinfo.json', 'Contents/moduleinfo.json'):
                (staged_plugin / relative).unlink(missing_ok=True)
        staged_binary = staged_plugin / 'Contents/MacOS/Plugin Auth Desk Fixture'
        subprocess.run(['/usr/bin/lipo', str(staged_binary), '-verify_arch', args.architecture],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        subprocess.run(['/usr/bin/lipo', str(host), '-verify_arch', args.architecture],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        staged_binary.chmod(0o755)
        subprocess.run([sys.executable, str(repository / 'scripts/signing_metadata.py'), str(staged_plugin)],
                       check=True, timeout=65)
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
            'initializeProcessor': not args.editor_only,
        }
        request_path = directory / 'request.json'
        request_path.write_text(json.dumps(request), encoding='utf-8')
        environment = os.environ.copy()
        event_log = directory / 'fixture-events.txt'
        environment['PAD_FIXTURE_EVENT_LOG'] = str(event_log)
        environment['PAD_FIXTURE_PAINTED'] = '1' if args.ocr_only else '0'
        environment.pop('PAD_FIXTURE_DELAY_MS', None)
        environment.pop('PAD_FIXTURE_CLEAR_REQUEST', None)
        environment.pop('PAD_FIXTURE_QUIT_DURING_INITIALIZATION', None)
        if args.cancel_during_initialization:
            environment['PAD_FIXTURE_QUIT_DURING_INITIALIZATION'] = str(directory / 'quit.request')
        if args.variant != 'normal':
            environment['PAD_FIXTURE_DELAY_MS'] = '2200'
        clear_request = directory / 'clear-fixture-label.request'
        if args.variant == 'transient':
            environment['PAD_FIXTURE_CLEAR_REQUEST'] = str(clear_request)
        process = subprocess.Popen(
            ['/usr/bin/arch', '-' + args.architecture, str(host), '--request', str(request_path)],
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
            while time.monotonic() - start < (12 if args.cancel_during_initialization else 30):
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
                            'probeDiagnostic': state.get('probeDiagnostic'),
                            'probePending': state.get('probePending'),
                            'phase': state.get('phase'),
                        })
                    elapsed = time.monotonic() - start
                    if state.get('state') == 'ready' and ready_seen is None:
                        ready_seen = elapsed
                    candidate = state.get('licenseCandidate')
                    valid_identity = (state.get('pid') == process.pid and state.get('scanMode') is True
                                      and state.get('architecture') == args.architecture
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
                        if args.ocr_only and state.get('probeDiagnostic') != 'ocr_matched':
                            report['failureReason'] = 'painted_fixture_did_not_require_ocr'
                            break
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
            events = event_log.read_text().splitlines() if event_log.exists() else []
            report['fixtureEvents'] = events
            if events.count('processor_created') != 1 or events.count('editor_created') != 1:
                report['result'] = 'failed'
                report['failureReason'] = 'selected_processor_and_editor_must_be_created_exactly_once'
            if 'audio_processed' in events:
                report['result'] = 'failed'
                report['failureReason'] = 'host_started_audio_processing'
            if args.editor_only:
                if 'processor_initialized' in events or events.count('editor_before_initialization') != 1 or latest.get('processorInitialized') is not False:
                    report['result'] = 'failed'
                    report['failureReason'] = 'initialization_opt_out_was_ignored'
            elif (events.count('processor_initialized') != 1
                  or events.count('editor_created') != 1
                  or 'editor_before_initialization' in events
                  or latest.get('processorInitialized') is not True
                  or events.index('processor_initialized') > events.index('editor_created')
                  or 'processor_released' not in events):
                report['result'] = 'failed'
                report['failureReason'] = 'processor_must_initialize_before_editor_and_release_without_rendering'
            if latest.get('phase') != 'observing' or latest.get('lastActivePhase') != 'observing' or not latest.get('readyAt'):
                report['result'] = 'failed'
                report['failureReason'] = 'missing_ready_phase_diagnostics'
            if latest.get('enumerationStrategy') != ('vst3_factory' if args.factory_metadata else 'vst3_moduleinfo'):
                report['result'] = 'failed'
                report['failureReason'] = 'expected_metadata_enumeration_path_was_not_used'
            if args.cancel_during_initialization:
                # This mode deliberately never has an editor/ready phase.
                # The fixture pumps the host's stop timer inside prepareToPlay,
                # reproducing a vendor's nested native initialization loop.
                cancelled = (events.count('processor_created') == 1
                             and events.count('processor_initialized') == 1
                             and events.count('stop_requested_during_initialization') == 1
                             and events.count('initialization_returned_after_nested_loop') == 1
                             and 'editor_created' not in events and 'audio_processed' not in events
                             and latest.get('lastActivePhase') == 'initializing_processor'
                             and not latest.get('readyAt')
                             and all(item.get('state') != 'ready' and not item.get('licenseEvidence') for item in timeline)
                             and report['elapsedSeconds'] < 12 and process.returncode in (0, 73))
                report['result'] = 'passed' if cancelled else 'failed'
                if cancelled:
                    report.pop('failureReason', None)
                else:
                    report['failureReason'] = 'stop_during_initialization_created_editor_or_reached_ready'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({key: report[key] for key in ['result', 'elapsedSeconds', 'childPID', 'cleanup', 'exitCode', 'childExited']}))
    print(str(output))
    return 0 if report['result'] == 'passed' and report['childExited'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
