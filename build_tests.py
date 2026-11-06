#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Installer and source-publication safety tests using isolated temporary data."""
import importlib.util
import os
import pathlib
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('auth_build', pathlib.Path(__file__).with_name('build.py'))
build = importlib.util.module_from_spec(spec)
# Import must not invoke subprocesses or change cwd.
before = pathlib.Path.cwd()
with mock.patch('subprocess.run', side_effect=AssertionError('subprocess during import')):
    spec.loader.exec_module(build)
assert pathlib.Path.cwd() == before


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.source = self.root/'build/Plugin Auth Desk.app'
        self.destination = self.root/'Applications/Plugin Auth Desk.app'
        self.backups = self.root/'Support/Backups'
        self.make_app(self.source, 'new')
        self.make_app(self.destination, 'old')
        self.running = mock.patch.object(build, 'running_processes', return_value=[])
        self.verify = mock.patch.object(build, 'verify_app')
        self.running.start()
        self.verifier = self.verify.start()
        self.addCleanup(self.running.stop)
        self.addCleanup(self.verify.stop)
        self.addCleanup(self.temp.cleanup)

    def make_app(self, app, version, identifier=build.BUNDLE_ID):
        (app/'Contents/MacOS').mkdir(parents=True)
        (app/'Contents/MacOS/PluginAuthDesk').write_text(version)
        with (app/'Contents/Info.plist').open('wb') as stream:
            plistlib.dump({'CFBundleIdentifier': identifier, 'CFBundleVersion': version}, stream)

    def marker(self, app):
        return (app/'Contents/MacOS/PluginAuthDesk').read_text()

    def install(self):
        return build.install_built_app(self.source, self.destination, self.backups)

    def assert_old_preserved(self):
        self.assertEqual(self.marker(self.destination), 'old')
        self.assertFalse(list(self.destination.parent.glob('.PluginAuthDesk-install-*')))

    def test_success_keeps_previous_backup(self):
        backup = self.install()
        self.assertEqual(self.marker(self.destination), 'new')
        self.assertEqual(self.marker(backup), 'old')
        self.assertEqual(self.verifier.call_count, 3)
        self.assertFalse(list(self.destination.parent.glob('.PluginAuthDesk-install-*')))

    def test_stage_copy_failure_leaves_old_untouched(self):
        with mock.patch.object(build.shutil, 'copytree', side_effect=OSError('disk full')):
            with self.assertRaises(OSError):
                self.install()
        self.assert_old_preserved()

    def test_stage_signature_failure_leaves_old_untouched(self):
        self.verifier.side_effect = [None, RuntimeError('bad signature')]
        with self.assertRaises(RuntimeError):
            self.install()
        self.assert_old_preserved()

    def test_final_verification_failure_rolls_back(self):
        self.verifier.side_effect = [None, None, RuntimeError('post-install check failed')]
        with self.assertRaises(RuntimeError):
            self.install()
        self.assert_old_preserved()

    def test_replacement_failure_rolls_back(self):
        original = os.replace
        def fail_new(source, target):
            if pathlib.Path(source).parent.name.startswith('.PluginAuthDesk-install-'):
                raise OSError('replacement failed')
            return original(source, target)
        with mock.patch.object(build.os, 'replace', side_effect=fail_new):
            with self.assertRaises(OSError):
                self.install()
        self.assert_old_preserved()

    def test_backup_move_failure_leaves_old_in_place(self):
        with mock.patch.object(build.os, 'replace', side_effect=OSError('cross filesystem')):
            with self.assertRaises(OSError):
                self.install()
        self.assert_old_preserved()

    def test_rollback_failure_retains_previous_backup(self):
        original = os.replace
        self.verifier.side_effect = [None, None, RuntimeError('post-install check failed')]
        def fail_restore(source, target):
            if self.backups in pathlib.Path(source).parents:
                raise OSError('restore temporarily unavailable')
            return original(source, target)
        with mock.patch.object(build.os, 'replace', side_effect=fail_restore):
            with self.assertRaisesRegex(RuntimeError, 'Previous app backup:'):
                self.install()
        backups = list(self.backups.glob('*/Plugin Auth Desk.app'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(self.marker(backups[0]), 'old')

    def test_first_install_failure_does_not_leave_invalid_app(self):
        import shutil
        shutil.rmtree(self.destination)
        self.verifier.side_effect = [None, None, RuntimeError('post-install check failed')]
        with self.assertRaises(RuntimeError):
            self.install()
        self.assertFalse(self.destination.exists())
        self.assertFalse(list(self.destination.parent.glob('.PluginAuthDesk-install-*')))

    def test_running_app_or_helper_is_rejected(self):
        for executable in ['Contents/MacOS/PluginAuthDesk',
                           'Contents/Helpers/AuthPluginHost.app/Contents/MacOS/AuthPluginHost']:
            with self.subTest(executable=executable), mock.patch.object(build, 'running_processes',
                    return_value=[str(self.destination/executable)]):
                with self.assertRaisesRegex(RuntimeError, 'running'):
                    self.install()
                self.assert_old_preserved()

    def test_app_started_during_copy_is_rejected(self):
        with mock.patch.object(build, 'running_processes', side_effect=[[],
                [str(self.destination/'Contents/MacOS/PluginAuthDesk')]]):
            with self.assertRaisesRegex(RuntimeError, 'running'):
                self.install()
        self.assert_old_preserved()

    def test_unrelated_destination_is_rejected(self):
        with (self.destination/'Contents/Info.plist').open('wb') as stream:
            plistlib.dump({'CFBundleIdentifier': 'another.app'}, stream)
        with self.assertRaisesRegex(RuntimeError, 'unrelated'):
            self.install()
        self.assert_old_preserved()

    def test_symlink_destination_is_rejected(self):
        original = self.destination.with_name('Original.app')
        os.replace(self.destination, original)
        self.destination.symlink_to(original, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'symlinked'):
            self.install()
        self.assertEqual(self.marker(original), 'old')


class SourceArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.juce = self.root / 'JUCE'
        self.juce.mkdir()
        (self.juce / 'modules').mkdir()
        (self.juce / 'modules/example.cpp').write_text('int fixture = 1;\n')
        (self.juce / 'tool.sh').write_text('#!/bin/sh\nexit 0\n')
        (self.juce / 'tool.sh').chmod(0o755)
        (self.juce / ('long-' + 'x' * 110 + '.txt')).write_text('long archive name\n')
        self.git('init', '-q')
        self.git('add', '.')
        self.git('-c', 'user.name=Synthetic Fixture', '-c', 'user.email=fixture@example.invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Synthetic source fixture')
        self.pin = mock.patch.object(build, 'JUCE_COMMIT', self.git('rev-parse', 'HEAD'))
        self.tree = mock.patch.object(build, 'JUCE_TREE', self.git('rev-parse', 'HEAD^{tree}'))
        self.pin.start()
        self.tree.start()
        self.addCleanup(self.pin.stop)
        self.addCleanup(self.tree.stop)
        (self.root / 'README.md').write_text('Public fixture sources\n')
        (self.root / 'build.py').write_text('# public fixture build\n')
        self.sources = mock.patch.object(build, 'SOURCE_FILES', ('README.md', 'build.py'))
        self.sources.start()
        self.addCleanup(self.sources.stop)

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.juce), *args], text=True).strip()

    def test_checkout_tree_matches_git_reference(self):
        files = build.dependency_sources(self.root)
        self.assertEqual(build.source_tree_hash(files), self.git('rev-parse', 'HEAD^{tree}'))
        self.assertEqual(len(files), 3)
        self.assertEqual(next(mode for name, mode, _ in files if name == 'tool.sh'), '100755')

    def test_wrong_commit_is_refused(self):
        with mock.patch.object(build, 'JUCE_COMMIT', '0' * 40):
            with self.assertRaisesRegex(RuntimeError, 'pinned commit'):
                build.dependency_sources(self.root)

    def test_modified_and_untracked_dependency_is_refused(self):
        for name in ['modules/example.cpp', 'private-state.json']:
            with self.subTest(name=name):
                path = self.juce / name
                old = path.read_bytes() if path.exists() else None
                path.write_text('changed\n')
                with self.assertRaisesRegex(RuntimeError, 'modified or untracked'):
                    build.dependency_sources(self.root)
                if old is None:
                    path.unlink()
                else:
                    path.write_bytes(old)

    def test_git_ignored_dependency_file_is_not_silently_packaged(self):
        (self.juce / '.git/info/exclude').write_text('private-state.json\n')
        (self.juce / 'private-state.json').write_text('private fixture data\n')
        self.assertEqual(self.git('status', '--porcelain=v1'), '')
        with self.assertRaisesRegex(RuntimeError, 'pinned source tree'):
            build.dependency_sources(self.root)

    def test_exported_sources_verify_without_git(self):
        shutil.rmtree(self.juce / '.git')
        with mock.patch.object(build.subprocess, 'check_output', side_effect=AssertionError('Git called')):
            self.assertEqual(len(build.dependency_sources(self.root)), 3)
            (self.juce / 'modules/example.cpp').write_text('tampered\n')
            with self.assertRaisesRegex(RuntimeError, 'pinned source tree'):
                build.dependency_sources(self.root)

    def test_source_archive_excludes_private_data_and_git_and_clears_metadata(self):
        for name in ['.env', 'license-state.json', 'inventory.json', 'build/private.log', 'results/scan.json',
                     '.local/notary-submission.json', 'notary-results/status.json', 'notarization-results/log.json']:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('must never be distributed\n')
        destination = self.root / 'Source.tar.gz'
        build.create_source_archive(destination, self.root)
        with tarfile.open(destination) as archive:
            entries = archive.getmembers()
            expected = {'PluginAuthDesk-source/' + name for name in ['README.md', 'build.py']}
            expected.update('PluginAuthDesk-source/JUCE/' + name
                            for name, _, _ in build.dependency_sources(self.root))
            self.assertEqual(set(archive.getnames()), expected)
            for entry in entries:
                with self.subTest(path=entry.name):
                    self.assertTrue(entry.isfile())
                    self.assertEqual((entry.uid, entry.gid, entry.uname, entry.gname, entry.mtime), (0, 0, '', '', 0))
                    self.assertEqual(entry.pax_headers, {})
                    self.assertIn(entry.mode, (0o644, 0o755))
                    self.assertNotIn('.git', pathlib.PurePosixPath(entry.name).parts)
        # The gzip header must not disclose an output filename or local time.
        header = destination.read_bytes()[:10]
        self.assertEqual(header[3], 0)
        self.assertEqual(header[4:8], b'\0' * 4)

    def test_archive_is_reproducible_after_local_time_changes(self):
        first, second = self.root / 'first.gz', self.root / 'second.gz'
        build.create_source_archive(first, self.root)
        os.utime(self.root / 'README.md', (12345, 12345))
        os.utime(self.juce / 'tool.sh', (67890, 67890))
        build.create_source_archive(second, self.root)
        self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_archive_export_can_be_verified_and_repackaged(self):
        archive = self.root / 'Source.tar.gz'
        build.create_source_archive(archive, self.root)
        unpacked = self.root / 'unpacked'
        unpacked.mkdir()
        with tarfile.open(archive) as source:
            # This test extracts only the regular, allowlisted archive just made.
            for entry in source.getmembers():
                target = unpacked / entry.name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(source.extractfile(entry).read())
                target.chmod(entry.mode)
        exported_root = unpacked / 'PluginAuthDesk-source'
        self.assertFalse((exported_root / 'JUCE/.git').exists())
        repacked = self.root / 'Repacked.tar.gz'
        build.create_source_archive(repacked, exported_root)
        self.assertEqual(archive.read_bytes(), repacked.read_bytes())

    def test_symlinked_first_party_source_is_refused(self):
        (self.root / 'README.md').unlink()
        (self.root / 'README.md').symlink_to('build.py')
        with self.assertRaisesRegex(RuntimeError, 'unsafe source'):
            build.create_source_archive(self.root / 'Source.tar.gz', self.root)


if __name__ == '__main__':
    unittest.main(verbosity=2)
