#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# SPDX-License-Identifier: AGPL-3.0-only
"""Build the local app, then install only after verifying a staged copy.

Importing this module has no build, filesystem, or current-directory side effects.
"""
import datetime
import gzip
import hashlib
import io
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import uuid

ROOT = pathlib.Path(__file__).resolve().parent
BUNDLE_ID = 'local.plugin-auth-desk'
VERSION = '1.3.3'
BUILD_NUMBER = '7'
JUCE_COMMIT = '72782788ce18c2d4d760b28e0921d6ffc6431102'
JUCE_TREE = 'd23fca239ebee89df5e81718a2fe16434b53118b'
# Explicit source distribution: never recursively add the project directory.
SOURCE_FILES = (
    '.gitattributes', '.gitignore', '.gitmodules', 'README.md', 'SECURITY.md',
    'THIRD_PARTY_NOTICES.md', 'COPYING', '使い方.md', 'CMakeLists.txt', 'build.py',
    'icon.swift', 'Inventory.swift', 'SessionLifecycle.swift', 'LicenseState.swift',
    'ActivationWorkflow.swift', 'AutoScan.swift', 'AutomaticScanner.swift',
    'main.swift', 'Host.cpp', 'LicenseProbe.h', 'LicenseProbe.mm',
    'license_probe_tests.mm', 'license_tests.swift', 'workflow_tests.swift',
    'model_tests.py', 'autoscan_tests.swift', 'auto_model_tests.py',
    'inventory_tests.swift', 'lifecycle_tests.swift', 'build_tests.py',
    'test_host_requests.py', 'tests/fixture/CMakeLists.txt',
    'tests/fixture/Fixture.cpp', 'tests/fixture/README.md',
    'tests/fixture/verify_installed_host.py',
    'docs/NOTARIZATION.md', 'packaging/host-entitlements.plist',
    'scripts/notarize.py', 'scripts/notarize_tests.py', 'scripts/signing_metadata.py',
)


def git_object_hash(kind, data):
    return hashlib.sha1(kind.encode('ascii') + b' ' + str(len(data)).encode('ascii')
                        + b'\0' + data).digest()


def source_tree_hash(files):
    """Compute a Git tree from (relative path, Git mode, bytes), without Git."""
    tree = {}
    for name, mode, data in files:
        parts = pathlib.PurePosixPath(name).parts
        if not parts or pathlib.PurePosixPath(name).is_absolute() or '..' in parts:
            raise RuntimeError('Unsafe dependency source path.')
        parent = tree
        for part in parts[:-1]:
            parent = parent.setdefault(part, {})
        parent[parts[-1]] = (mode, git_object_hash('blob', data))

    def digest(node):
        payload = bytearray()
        for name, value in sorted(node.items(),
                key=lambda item: item[0].encode('utf-8') + (b'/' if isinstance(item[1], dict) else b'')):
            mode, object_id = ('40000', digest(value)) if isinstance(value, dict) else value
            payload += mode.encode('ascii') + b' ' + name.encode('utf-8') + b'\0' + object_id
        return git_object_hash('tree', payload)
    return digest(tree).hex()


def dependency_sources(root=ROOT):
    """Verify a clean pinned checkout, or the same source tree without Git.

    The fixed tree hash verifies archive exports without trusting a generated
    manifest or requiring repository history to be included in Source.tar.gz.
    """
    juce = pathlib.Path(root) / 'JUCE'
    if juce.is_symlink() or not juce.is_dir():
        raise RuntimeError('Initialize the pinned JUCE submodule before building.')
    if (juce / '.git').exists():
        def git(*args):
            return subprocess.check_output(['git', '-C', str(juce), *args], text=True).strip()
        if pathlib.Path(git('rev-parse', '--show-toplevel')).resolve() != juce.resolve():
            raise RuntimeError('JUCE must be its own pinned submodule checkout.')
        if git('rev-parse', 'HEAD') != JUCE_COMMIT:
            raise RuntimeError('JUCE does not match the pinned commit ' + JUCE_COMMIT)
        if git('status', '--porcelain=v1', '--untracked-files=all'):
            raise RuntimeError('JUCE has modified or untracked files; use a clean pinned checkout.')
    files = []
    for directory, directories, filenames in os.walk(juce, followlinks=False):
        current = pathlib.Path(directory)
        if current == juce:
            directories[:] = [name for name in directories if name != '.git']
            filenames = [name for name in filenames if name != '.git']
        for name in directories:
            if (current / name).is_symlink():
                raise RuntimeError('Unexpected symlink in JUCE sources.')
        for name in filenames:
            path = current / name
            if path.is_symlink() or not path.is_file():
                raise RuntimeError('Unexpected non-regular JUCE source.')
            mode = '100755' if path.stat().st_mode & 0o111 else '100644'
            files.append((path.relative_to(juce).as_posix(), mode, path.read_bytes()))
    files.sort(key=lambda item: item[0])
    if source_tree_hash(files) != JUCE_TREE:
        raise RuntimeError('JUCE source contents do not match the pinned source tree. '
                           'Remove generated/extra files or restore the pinned submodule.')
    return files


def create_source_archive(destination, root=ROOT):
    """Package only approved sources, with reproducible anonymous metadata."""
    root = pathlib.Path(root)
    files = []
    for name in SOURCE_FILES:
        path = root / name
        if path.is_symlink() or not path.is_file() or root.resolve() not in path.resolve().parents:
            raise RuntimeError('Missing or unsafe source distribution file: ' + name)
        # Source scripts are invoked through Python/Swift, so no local mode leaks.
        files.append((name, 0o644, path.read_bytes()))
    files.extend(('JUCE/' + name, 0o755 if mode == '100755' else 0o644, data)
                 for name, mode, data in dependency_sources(root))
    with pathlib.Path(destination).open('wb') as output:
        with gzip.GzipFile(filename='', mode='wb', fileobj=output, mtime=0) as compressed:
            # GNU long-name entries preserve relative source paths without PAX
            # headers inherited from the filesystem (atime, ctime, path, xattrs).
            with tarfile.open(fileobj=compressed, mode='w', format=tarfile.GNU_FORMAT) as archive:
                for name, mode, data in sorted(files):
                    entry = tarfile.TarInfo('PluginAuthDesk-source/' + name)
                    entry.size, entry.mode = len(data), mode
                    entry.uid = entry.gid = entry.mtime = 0
                    entry.uname = entry.gname = ''
                    archive.addfile(entry, io.BytesIO(data))


def run(args):
    subprocess.run([str(x) for x in args], check=True)


def verify_app(app):
    run(['codesign', '--verify', '--deep', '--strict', app])


def validate_app_identity(app):
    app = pathlib.Path(app)
    if app.is_symlink():
        raise RuntimeError('Refusing to replace or copy a symlinked app: ' + str(app))
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleIdentifier') != BUNDLE_ID:
        raise RuntimeError('Refusing to replace or copy an unrelated app: ' + str(app))


def running_processes():
    # comm contains executable paths, not argv or user-provided license material.
    return subprocess.check_output(['/bin/ps', '-axo', 'comm='], text=True).splitlines()


def assert_not_running(*apps):
    prefixes = {str(path) + '/Contents/' for app in apps
                for path in (pathlib.Path(app).absolute(), pathlib.Path(app).resolve())}
    for line in running_processes():
        executable = line.strip()
        if any(executable.startswith(prefix) for prefix in prefixes):
            raise RuntimeError('Plugin Auth Desk or its plug-in host is running. '
                               'Quit Plugin Auth Desk before installing an update.')


def install_built_app(app, destination, backup_root):
    """Verify before mutation; retain the previous app and roll back on failure.

    The staged app lives on the destination filesystem. The old app is renamed
    into a unique backup directory and is never deleted by an update. If this
    rename cannot be performed (including EXDEV), the original stays in place.
    """
    app, destination, backup_root = map(pathlib.Path, (app, destination, backup_root))
    validate_app_identity(app)
    verify_app(app)
    if destination.exists() or destination.is_symlink():
        validate_app_identity(destination)
    assert_not_running(app, destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage_root = pathlib.Path(tempfile.mkdtemp(prefix='.PluginAuthDesk-install-', dir=destination.parent))
    staged = stage_root / destination.name
    backup = None
    backup_directory = None
    moved_previous = False
    installed_new = False
    try:
        shutil.copytree(app, staged, copy_function=shutil.copy)
        validate_app_identity(staged)
        verify_app(staged)
        # Recheck after a potentially slow copy. No running process is killed.
        assert_not_running(app, destination)
        if destination.exists() or destination.is_symlink():
            validate_app_identity(destination)
            stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
            backup_directory = backup_root / (stamp + '-' + uuid.uuid4().hex[:12])
            backup_directory.mkdir(parents=True, exist_ok=False)
            backup = backup_directory / destination.name
            os.replace(destination, backup)
            moved_previous = True
        os.replace(staged, destination)
        installed_new = True
        verify_app(destination)
    except BaseException as error:
        try:
            if installed_new:
                # Preserve it inside our staging directory until rollback is done.
                os.replace(destination, stage_root / 'Rejected Update.app')
            if moved_previous:
                os.replace(backup, destination)
        except BaseException as rollback_error:
            raise RuntimeError('Update failed and automatic rollback failed. Previous app backup: '
                               + str(backup) + '; rollback error: ' + str(rollback_error)) from error
        raise
    finally:
        shutil.rmtree(stage_root)
        if backup_directory is not None:
            try:
                backup_directory.rmdir()  # Empty only after rollback/failed rename.
            except OSError:
                pass
    return backup


def build_app():
    dependency_sources()
    cmake = shutil.which('cmake')
    if cmake is None:
        raise RuntimeError('CMake 3.22+ is required on PATH.')
    dist = ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    run([cmake, '-S', ROOT, '-B', ROOT/'build', '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64'])
    run([cmake, '--build', ROOT/'build', '--config', 'Release', '-j', '6'])
    run(['xcrun', 'swiftc', '-O', '-swift-version', '5', '-target', 'arm64-apple-macosx12.0',
         '-framework', 'Cocoa', '-framework', 'SwiftUI', 'Inventory.swift', 'SessionLifecycle.swift', 'LicenseState.swift', 'ActivationWorkflow.swift', 'AutoScan.swift', 'AutomaticScanner.swift',
         'main.swift', '-o', dist/'PluginAuthDesk'])
    # The public checkout owns its build products; never touch a pre-existing
    # private build cache or installed application during a normal build.
    app = dist / 'Plugin Auth Desk.app'
    assert_not_running(app)
    if app.exists() or app.is_symlink():
        validate_app_identity(app)
        shutil.rmtree(app)
    contents = app / 'Contents'
    for name in ['MacOS', 'Helpers', 'Resources']:
        (contents/name).mkdir(parents=True)
    shutil.copy2(dist/'PluginAuthDesk', contents/'MacOS/PluginAuthDesk')
    helper = contents/'Helpers/AuthPluginHost.app'
    shutil.copytree('build/AuthPluginHost_artefacts/Release/AuthPluginHost.app', helper)
    info = dict(CFBundleExecutable='PluginAuthDesk', CFBundleIdentifier=BUNDLE_ID,
        CFBundleName='Plugin Auth Desk', CFBundleDisplayName='Plugin Auth Desk', CFBundlePackageType='APPL',
        CFBundleShortVersionString=VERSION, CFBundleVersion=BUILD_NUMBER, LSMinimumSystemVersion='12.0',
        NSHighResolutionCapable=True, CFBundleIconFile='AppIcon', NSPrincipalClass='NSApplication',
        NSHumanReadableCopyright='Local Tools. AGPLv3. Includes JUCE and third-party components.')
    with (contents/'Info.plist').open('wb') as stream:
        plistlib.dump(info, stream)
    run(['xcrun', 'swift', 'icon.swift', dist/'AppIcon.iconset'])
    run(['iconutil', '-c', 'icns', dist/'AppIcon.iconset', '-o', contents/'Resources/AppIcon.icns'])
    create_source_archive(contents/'Resources/Source.tar.gz')
    for name in ['README.md', 'SECURITY.md', 'THIRD_PARTY_NOTICES.md', '使い方.md', 'COPYING']:
        shutil.copy2(name, contents/'Resources'/name)
    shutil.copy2('JUCE/LICENSE.md', contents/'Resources/JUCE-LICENSE.md')
    shutil.copy2('JUCE/JUCE.spdx.json', contents/'Resources/JUCE.spdx.json')
    # Strip only signing-incompatible Finder metadata; preserve quarantine.
    run([sys.executable, ROOT/'scripts/signing_metadata.py', app])
    run(['codesign', '--force', '--sign', '-', helper])
    run(['codesign', '--force', '--sign', '-', app])
    verify_app(app)
    return app


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    if any(arg != '--install' for arg in args):
        raise RuntimeError('Usage: python3 build.py [--install]')
    destination = pathlib.Path.home() / 'Applications/Plugin Auth Desk.app'
    if '--install' in args:
        assert_not_running(destination)
    previous_directory = pathlib.Path.cwd()
    try:
        os.chdir(ROOT)
        app = build_app()
        if '--install' in args:
            backup = install_built_app(app, destination,
                pathlib.Path.home()/'Library/Application Support/Plugin Auth Desk/Backups')
            if backup is not None:
                print('Previous version backup:', backup)
            print(destination)
        else:
            print(app)
    finally:
        os.chdir(previous_directory)


if __name__ == '__main__':
    main()
