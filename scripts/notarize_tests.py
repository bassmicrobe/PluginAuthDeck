#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Synthetic release-state tests. Never sign, submit, or launch an app."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location('release', Path(__file__).with_name('notarize.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
SUBMISSION = '11111111-2222-4333-8444-555555555555'


class FakeCommands:
    def __init__(self, run, state, status='Accepted', submit_code=0):
        self.run, self.state, self.status, self.submit_code = run, state, status, submit_code
        self.calls = []

    def call(self, label, args, timeout=120, output=None, check=True):
        self.calls.append(label)
        out, err = self.run / (output or label + '.out'), self.run / (label + '.err')
        out.write_text('')
        err.write_text('')
        code = 0
        if label == 'find-identity':
            out.write_text('1) ' + self.state['identity'] + ' "Developer ID Application: Fixture (' + self.state['team_id'] + ')"\n')
        elif label == 'copy-source':
            shutil.copytree(args[-2], args[-1])
        elif label in ('sign-helper', 'sign-launcher'):
            assert not list((self.run / release.APP_NAME).rglob('*.cstemp')), 'stale codesign files reached signing'
        elif label == 'submission-zip':
            (self.run / 'submission.zip').write_bytes(b'synthetic signed submission')
        elif label == 'submit':
            assert release.read_json(self.run / 'state.json')['stage'] == 'submitting'
            out.write_text(json.dumps({'id': SUBMISSION}))
            code = self.submit_code
        elif label == 'wait':
            out.write_text(json.dumps({'id': SUBMISSION, 'status': self.status}))
        elif label == 'notary-log':
            (self.run / 'notary-log.json').write_text(json.dumps({
                'jobId': SUBMISSION, 'sha256': self.state['submission_sha256'], 'status': self.status}))
        elif label == 'staple':
            (self.run / release.APP_NAME / 'synthetic-ticket').write_bytes(b'ticket')
        elif label == 'distribution-zip':
            with zipfile.ZipFile(args[-1], 'w') as archive:
                for file in (self.run / release.APP_NAME).rglob('*'):
                    if file.is_file():
                        archive.write(file, file.relative_to(self.run))
        elif label == 'extract-distribution':
            with zipfile.ZipFile(args[-2]) as archive:
                archive.extractall(args[-1])
        elif label in ('gatekeeper', 'assess-extracted'):
            err.write_text('accepted\nsource=Notarized Developer ID\n')
        return out, err, {'returncode': code}


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='notary-state-fixture-')
        self.run = Path(self.temporary.name)
        self.state = {'schema': 1, 'stage': 'prepared', 'profile': 'synthetic-profile', 'version': '1.3.2',
                      'identity': '1' * 40, 'team_id': 'TESTTEAM01', 'keychain': '/synthetic/keychain',
                      'signatures': {'synthetic': 'unchanged'}}
        release.atomic_json(self.run / 'state.json', self.state)

    def tearDown(self):
        self.temporary.cleanup()

    def submitted(self, stage='submitted'):
        (self.run / 'submission.zip').write_bytes(b'synthetic signed submission')
        self.state.update(stage=stage, submission_sha256=release.sha256(self.run / 'submission.zip'))
        if stage == 'submitted':
            self.state['submission_id'] = SUBMISSION
        release.atomic_json(self.run / 'state.json', self.state)

    def test_fresh_submit_saves_intent_then_id_before_wait(self):
        commands = FakeCommands(self.run, self.state)
        release.resume_submission(self.run, self.state, commands)
        self.assertEqual(commands.calls, ['submission-zip', 'submit', 'wait', 'notary-log'])
        self.assertEqual(release.read_json(self.run / 'state.json')['submission_id'], SUBMISSION)
        self.assertEqual(self.state['stage'], 'accepted')

    def test_saved_id_is_never_resubmitted(self):
        self.submitted()
        commands = FakeCommands(self.run, self.state)
        release.resume_submission(self.run, self.state, commands)
        self.assertEqual(commands.calls, ['wait', 'notary-log'])

    def test_ambiguous_submit_does_not_retry(self):
        self.submitted('submitting')
        commands = FakeCommands(self.run, self.state)
        with self.assertRaisesRegex(RuntimeError, 'no automatic resubmission'):
            release.resume_submission(self.run, self.state, commands)
        self.assertEqual(commands.calls, [])

    def test_interrupted_submit_recovers_recorded_id(self):
        self.submitted('submitting')
        release.atomic_json(self.run / 'submission.json', {'id': SUBMISSION})
        commands = FakeCommands(self.run, self.state)
        release.resume_submission(self.run, self.state, commands)
        self.assertEqual(commands.calls, ['wait', 'notary-log'])

    def test_manual_recovery_still_checks_archive_receipt(self):
        self.submitted('submitting')
        commands = FakeCommands(self.run, self.state)
        release.resume_submission(self.run, self.state, commands, SUBMISSION)
        self.assertEqual(self.state['stage'], 'accepted')
        self.assertNotIn('submit', commands.calls)

    def test_failed_submit_keeps_any_returned_id(self):
        commands = FakeCommands(self.run, self.state, submit_code=1)
        with self.assertRaises(RuntimeError):
            release.resume_submission(self.run, self.state, commands)
        self.assertEqual(release.read_json(self.run / 'state.json')['submission_id'], SUBMISSION)
        self.assertEqual(self.state['stage'], 'submitted')
        self.assertNotIn('wait', commands.calls)

    def test_invalid_status_cannot_advance_to_staple(self):
        self.submitted()
        commands = FakeCommands(self.run, self.state, status='Invalid')
        with self.assertRaisesRegex(RuntimeError, 'not Accepted'):
            release.resume_submission(self.run, self.state, commands)
        self.assertEqual(self.state['stage'], 'submitted')
        self.assertTrue((self.run / 'notary-log.json').is_file())

    def test_modified_submission_is_rejected_before_network(self):
        self.submitted()
        (self.run / 'submission.zip').write_bytes(b'changed')
        commands = FakeCommands(self.run, self.state)
        with self.assertRaisesRegex(RuntimeError, 'ZIP was changed'):
            release.resume_submission(self.run, self.state, commands)
        self.assertEqual(commands.calls, [])

    def test_saved_id_cannot_return_to_preparation(self):
        self.submitted()
        self.state['stage'] = 'prepared'
        with self.assertRaisesRegex(RuntimeError, 'saved submission ID'):
            release.validate_settings(self.state)

    def test_output_cannot_modify_source_or_another_app(self):
        source = self.run / 'source.app'
        for destination in (source, source / 'runs', self.run / 'other.app/runs'):
            with self.assertRaisesRegex(RuntimeError, 'outside the source'):
                release.validate_output_root(source, destination)
        release.validate_output_root(source, self.run / 'results')

    def test_final_zip_contains_stapled_parent_bundle_and_matches_hash(self):
        app = self.run / release.APP_NAME
        app.mkdir()
        (app / 'synthetic-code').write_bytes(b'fixture')
        self.state['stage'] = 'accepted'
        commands = FakeCommands(self.run, self.state)
        with patch.object(release, 'verify_signatures', return_value=self.state['signatures']):
            release.finish(self.run, self.state, commands)
        archive = self.run / self.state['archive']
        with zipfile.ZipFile(archive) as bundle:
            self.assertIn(release.APP_NAME + '/synthetic-ticket', bundle.namelist())
            self.assertTrue(all(name.startswith(release.APP_NAME + '/') for name in bundle.namelist()))
        self.assertEqual(self.state['archive_sha256'], hashlib.sha256(archive.read_bytes()).hexdigest())
        self.assertEqual(self.state['stage'], 'complete')
        self.assertIn('validate-extracted-ticket', commands.calls)
        self.assertIn('assess-extracted', commands.calls)

    def test_tree_fingerprint_rejects_symlinks(self):
        app = self.run / release.APP_NAME
        app.mkdir()
        (app / 'link').symlink_to(self.run / 'outside')
        with self.assertRaisesRegex(RuntimeError, 'symlink'):
            release.tree_digest(app)

    def test_every_interrupted_preparation_restarts_without_codesign_temporary_files(self):
        source = self.run / 'source.app'
        (source / 'Contents/MacOS').mkdir(parents=True)
        (source / 'Contents/MacOS/AuthPluginHost').write_bytes(b'original synthetic executable')
        original_digest = release.tree_digest(source)
        for stage in sorted(release.PREPARING):
            with self.subTest(stage=stage):
                attempt = self.run / stage
                attempt.mkdir()
                app = attempt / release.APP_NAME
                shutil.copytree(source, app)
                leftover = app / 'Contents/MacOS/AuthPluginHost.cstemp'
                leftover.write_bytes(b'incomplete signature')
                state = dict(self.state, stage=stage, source=str(source), source_digest=original_digest)
                commands = FakeCommands(attempt, state)
                with patch.object(release, 'verify_signatures', return_value={'synthetic': 'fresh'}):
                    release.prepare(attempt, state, commands)
                self.assertEqual(state['stage'], 'prepared')
                self.assertEqual(release.tree_digest(app), original_digest)
                self.assertEqual(release.tree_digest(source), original_digest)
                self.assertEqual(commands.calls, ['find-identity', 'copy-source', 'clear-staged-signing-metadata', 'sign-helper', 'sign-launcher'])
                retained = attempt / state['failed_preparations'][0]
                self.assertEqual((retained / leftover.relative_to(app)).read_bytes(), b'incomplete signature')

    def test_submitted_preparation_never_copies_or_signs(self):
        self.state.update(stage='signing_helper', submission_id=SUBMISSION)
        commands = FakeCommands(self.run, self.state)
        with self.assertRaisesRegex(RuntimeError, 'unsubmitted preparation'):
            release.prepare(self.run, self.state, commands)
        self.assertEqual(commands.calls, [])

    def test_first_preparation_signs_a_fresh_copy_without_backup(self):
        source = self.run / 'source.app'
        source.mkdir()
        (source / 'synthetic-code').write_bytes(b'original')
        self.state.update(stage='copying', source=str(source), source_digest=release.tree_digest(source))
        commands = FakeCommands(self.run, self.state)
        with patch.object(release, 'verify_signatures', return_value={'synthetic': 'fresh'}):
            release.prepare(self.run, self.state, commands)
        self.assertEqual(self.state['stage'], 'prepared')
        self.assertNotIn('failed_preparations', self.state)
        self.assertEqual(release.tree_digest(self.run / release.APP_NAME), release.tree_digest(source))

    def test_command_failure_and_timeout_keep_logs(self):
        commands = release.Commands(self.run)
        result = commands.call('synthetic-failure', [sys.executable, '-c', 'print("fixture"); raise SystemExit(7)'], check=False)
        self.assertEqual(result[2]['returncode'], 7)
        self.assertIn('fixture', result[0].read_text())
        result = commands.call('synthetic-timeout', [sys.executable, '-c', 'import time; time.sleep(5)'], timeout=0.05, check=False)
        self.assertTrue(result[2]['timed_out'])
        self.assertEqual(len(list((self.run / 'logs').glob('*.json'))), 2)


if __name__ == '__main__':
    unittest.main()
