#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Sign an isolated copy, resume one notarization, and verify its final ZIP.

No credentials are embedded or accepted as passwords. No app/plugin is launched.
All commands, including failures/timeouts, retain their output in a private run.
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
APP_NAME = 'Plugin Auth Desk.app'
HELPER = 'Contents/Helpers/AuthPluginHost.app'
ENTITLEMENTS = {
    'com.apple.security.cs.disable-library-validation': True,
    'com.apple.security.cs.allow-unsigned-executable-memory': True,
}
PREPARING = {'copying', 'signing_helper', 'signing_app', 'verifying_signature'}
STAGES = PREPARING | {'prepared', 'submitting', 'submitted', 'accepted', 'stapling', 'complete'}


def atomic_json(path, value):
    temporary = path.with_name(path.name + '.tmp-' + uuid.uuid4().hex)
    with temporary.open('x', encoding='utf-8') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def tree_digest(app):
    """Fingerprint regular files, relative names and executable modes; reject links."""
    if app.is_symlink() or not app.is_dir():
        raise RuntimeError('Expected a regular app directory: ' + str(app))
    digest = hashlib.sha256()
    for path in sorted(app.rglob('*')):
        if path.is_symlink():
            raise RuntimeError('Unexpected symlink in this app layout: ' + str(path))
        if path.is_dir():
            continue
        if not path.is_file():
            raise RuntimeError('Unexpected non-regular app file: ' + str(path))
        entry = [path.relative_to(app).as_posix(), path.stat().st_mode & 0o777, sha256(path)]
        digest.update(json.dumps(entry, ensure_ascii=False).encode('utf-8') + b'\n')
    return digest.hexdigest()


class Commands:
    def __init__(self, run):
        self.run = run
        self.logs = run / 'logs'
        self.logs.mkdir(exist_ok=True)

    def call(self, label, args, timeout=120, output=None, check=True):
        stamp = label + '-' + uuid.uuid4().hex[:10]
        stdout = self.run / output if output else self.logs / (stamp + '.stdout')
        stderr = self.logs / (stamp + '.stderr')
        record = {'command': [str(arg) for arg in args], 'timeout_seconds': timeout,
                  'stdout': str(stdout.relative_to(self.run)), 'stderr': str(stderr.relative_to(self.run)),
                  'started': datetime.datetime.now(datetime.timezone.utc).isoformat()}
        meta = self.logs / (stamp + '.json')
        atomic_json(meta, record)
        env = dict(os.environ, LC_ALL='C')
        print(label, flush=True)
        with stdout.open('wb') as out, stderr.open('wb') as err:
            process = subprocess.Popen(record['command'], stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                       start_new_session=True, env=env)
            try:
                record['returncode'] = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                record['timed_out'] = True
                # Signal only the new process group owned by this command.
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                try:
                    record['returncode'] = process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    record['returncode'] = process.wait(timeout=5)
            finally:
                record['finished'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
                atomic_json(meta, record)
        if check and (record.get('timed_out') or record['returncode'] != 0):
            raise RuntimeError(label + ' failed or timed out; retained logs: ' + str(meta))
        return stdout, stderr, record


def require_success(result, label):
    if result[2].get('timed_out') or result[2].get('returncode') != 0:
        raise RuntimeError(label + ' failed or timed out; keep this run and resume it, not a new submission.')


def read_json(path):
    try:
        value = json.loads(path.read_text(encoding='utf-8'))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def validate_settings(state):
    if not re.fullmatch(r'[A-F0-9]{40}', state.get('identity', '')):
        raise RuntimeError('Provide the explicit 40-character signing certificate SHA-1.')
    if not re.fullmatch(r'[A-Z0-9]{10}', state.get('team_id', '')):
        raise RuntimeError('Provide the explicit 10-character Developer Team ID.')
    if not state.get('profile') or not Path(state.get('keychain', '')).is_absolute():
        raise RuntimeError('Provide a notarytool profile name and absolute signing-keychain path.')
    if state.get('stage') not in STAGES or state.get('schema') != 1:
        raise RuntimeError('Unsupported or damaged run state.')
    if state.get('submission_id') and (not valid_submission_id(state['submission_id'])
            or state['stage'] in PREPARING | {'prepared'}):
        raise RuntimeError('A saved submission ID cannot return to signing or a fresh submission.')


def validate_output_root(source, output):
    resolved = output.resolve()
    if source.resolve() == resolved or source.resolve() in resolved.parents \
            or any(path.suffix == '.app' for path in (resolved, *resolved.parents)):
        raise RuntimeError('The output directory must be outside the source and any existing app bundle.')


def bundle_info(app):
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleIdentifier') != 'local.plugin-auth-desk' or info.get('CFBundleExecutable') != 'PluginAuthDesk':
        raise RuntimeError('This release script only handles the Plugin Auth Desk bundle layout.')
    version = info.get('CFBundleShortVersionString', '')
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+)*', version):
        raise RuntimeError('Unsupported bundle version.')
    helper = app / HELPER
    with (helper / 'Contents/Info.plist').open('rb') as stream:
        helper_info = plistlib.load(stream)
    if helper_info.get('CFBundleIdentifier') != 'local.plugin-auth-desk.host':
        raise RuntimeError('Unexpected embedded helper.')
    return version


def verify_signatures(commands, app, state):
    """Check all architectures, exact leaf identity, team, runtime and entitlements."""
    commands.call('verify-code', ['/usr/bin/codesign', '--verify', '--deep', '--strict', '--verbose=2', app])
    signatures = {}
    for name, target, executable, architectures, entitlements in [
        ('launcher', app, 'PluginAuthDesk', {'arm64'}, {}),
        ('helper', app / HELPER, 'AuthPluginHost', {'arm64', 'x86_64'}, ENTITLEMENTS),
    ]:
        result = commands.call('architectures-' + name, ['/usr/bin/lipo', '-archs', target / 'Contents/MacOS' / executable])
        if set(result[0].read_text().split()) != architectures:
            raise RuntimeError('Unexpected architecture set for ' + name)
        for arch in sorted(architectures):
            result = commands.call('signature-' + name + '-' + arch,
                ['/usr/bin/codesign', '-d', '--verbose=4', '--arch', arch, target])
            description = result[0].read_text() + result[1].read_text()
            if ('TeamIdentifier=' + state['team_id'] + '\n') not in description \
                    or 'Authority=Developer ID Application:' not in description \
                    or 'runtime' not in description or not re.search(r'^Timestamp=.+$', description, re.M):
                raise RuntimeError('Developer ID, team, hardened runtime or timestamp mismatch: ' + name)
            cdhash = re.search(r'^CDHash=([a-fA-F0-9]+)$', description, re.M)
            if not cdhash:
                raise RuntimeError('Missing code-directory hash.')
            signatures[name + '-' + arch] = cdhash.group(1).lower()
            result = commands.call('entitlements-' + name + '-' + arch,
                ['/usr/bin/codesign', '-d', '--arch', arch, '--entitlements', ':-', target])
            raw = result[0].read_bytes().strip()
            actual = plistlib.loads(raw) if raw else {}
            if actual != entitlements:
                raise RuntimeError('Unexpected entitlements: ' + name)
            certificate_prefix = commands.logs / ('certificate-' + name + '-' + arch + '-' + uuid.uuid4().hex + '-')
            commands.call('certificate-' + name + '-' + arch, ['/usr/bin/codesign', '-d', '--arch', arch,
                '--extract-certificates=' + str(certificate_prefix), target])
            certificate = Path(str(certificate_prefix) + '0').read_bytes()
            if hashlib.sha1(certificate).hexdigest().upper() != state['identity']:
                raise RuntimeError('Embedded leaf certificate does not match the selected SHA-1.')
    return signatures


def prepare(run, state, commands):
    if state['stage'] not in PREPARING or state.get('submission_id'):
        raise RuntimeError('Only an unsubmitted preparation may be rebuilt from a fresh copy.')
    app = run / APP_NAME
    source = Path(state['source'])
    if tree_digest(source) != state['source_digest']:
        raise RuntimeError('The source build changed; preserve this run and create a new run from the new build.')
    identity = commands.call('find-identity', ['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning', state['keychain']])
    pattern = re.compile(r'\b' + state['identity'] + r'\s+"Developer ID Application:.*\(' + state['team_id'] + r'\)"')
    if not pattern.search(identity[0].read_text()):
        raise RuntimeError('The selected keychain has no matching valid Developer ID Application identity/team.')
    # Interrupted codesign can leave *.cstemp files. Re-signing that copy may
    # seal a temporary file which codesign later removes, producing a broken
    # resource envelope. Every PREPARING restart therefore retains the old
    # copy for diagnosis and signs a fresh, byte-checked source copy instead.
    state['stage'] = 'copying'
    atomic_json(run / 'state.json', state)
    if app.exists() or app.is_symlink():
        previous = run / ('failed-preparation-' + uuid.uuid4().hex + '.app')
        app.rename(previous)
        state.setdefault('failed_preparations', []).append(previous.name)
        atomic_json(run / 'state.json', state)
    commands.call('copy-source', ['/usr/bin/ditto', source, app], timeout=300)
    if tree_digest(app) != state['source_digest']:
        raise RuntimeError('Staged app copy differs from the source.')
    commands.call('clear-staged-signing-metadata', [sys.executable, ROOT / 'scripts/signing_metadata.py', app])
    state['stage'] = 'signing_helper'
    atomic_json(run / 'state.json', state)
    sign = ['/usr/bin/codesign', '--force', '--sign', state['identity'], '--keychain', state['keychain'], '--options', 'runtime', '--timestamp']
    commands.call('sign-helper', sign + ['--entitlements', run / 'host-entitlements.plist', app / HELPER])
    state['stage'] = 'signing_app'
    atomic_json(run / 'state.json', state)
    commands.call('sign-launcher', sign + [app])
    state['stage'] = 'verifying_signature'
    atomic_json(run / 'state.json', state)
    state['signatures'] = verify_signatures(commands, app, state)
    state['signed_digest'] = tree_digest(app)
    state['stage'] = 'prepared'
    atomic_json(run / 'state.json', state)


def valid_submission_id(value):
    try:
        return str(uuid.UUID(value)) if isinstance(value, str) else None
    except ValueError:
        return None


def resume_submission(run, state, commands, supplied_id=None):
    """No second submit after an ID exists, or after an ambiguous interrupted submit."""
    archive = run / 'submission.zip'
    auth = ['--keychain-profile', state['profile']]
    if supplied_id:
        supplied_id = valid_submission_id(supplied_id)
        if not supplied_id or state['stage'] != 'submitting' or state.get('submission_id'):
            raise RuntimeError('--submission-id is only for an interrupted submission with no saved ID.')
        state['submission_id'] = supplied_id
        state['stage'] = 'submitted'
        atomic_json(run / 'state.json', state)
    if state['stage'] == 'prepared':
        commands.call('submission-zip', ['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', run / APP_NAME, archive], timeout=300)
        state['submission_sha256'] = sha256(archive)
        state['stage'] = 'submitting'
        atomic_json(run / 'state.json', state)  # Persist intent BEFORE any network submission.
        result = commands.call('submit', ['/usr/bin/xcrun', 'notarytool', 'submit', archive, *auth, '--output-format', 'json'],
                               timeout=600, output='submission.json', check=False)
        submission_id = valid_submission_id(read_json(run / 'submission.json').get('id'))
        if submission_id:
            state['submission_id'] = submission_id
            state['stage'] = 'submitted'
            atomic_json(run / 'state.json', state)
        require_success(result, 'Submission')
    if state['stage'] == 'submitting':
        submission_id = valid_submission_id(read_json(run / 'submission.json').get('id'))
        if not submission_id:
            raise RuntimeError('Submission outcome is unknown; no automatic resubmission. Inspect notarytool history, '
                               'then use --resume with --submission-id for the matching upload.')
        state['submission_id'], state['stage'] = submission_id, 'submitted'
        atomic_json(run / 'state.json', state)
    if sha256(archive) != state['submission_sha256']:
        raise RuntimeError('The notarization submission ZIP was changed.')
    if state['stage'] == 'submitted':
        result = commands.call('wait', ['/usr/bin/xcrun', 'notarytool', 'wait', state['submission_id'], *auth,
            '--timeout', '10m', '--output-format', 'json'], timeout=630, output='notary-status.json', check=False)
        status = read_json(run / 'notary-status.json')
        state['last_notary_status'] = status.get('status', 'unknown')
        atomic_json(run / 'state.json', state)
        if status.get('status') in {'Accepted', 'Invalid', 'Rejected'}:
            log = commands.call('notary-log', ['/usr/bin/xcrun', 'notarytool', 'log', state['submission_id'], *auth,
                run / 'notary-log.json'], timeout=120, check=False)
            if status.get('status') == 'Accepted':
                require_success(log, 'Notary log retrieval')
        require_success(result, 'Notary wait')
        if status.get('status') != 'Accepted':
            raise RuntimeError('Notarization is not Accepted; inspect the retained status/log and resume the same ID.')
        log = read_json(run / 'notary-log.json')
        if log.get('jobId') != state['submission_id'] or log.get('sha256') != state['submission_sha256'] or log.get('status') != 'Accepted':
            raise RuntimeError('Accepted notarization log does not match this exact submission archive.')
        state['stage'] = 'accepted'
        atomic_json(run / 'state.json', state)


def finish(run, state, commands):
    app = run / APP_NAME
    if state['stage'] == 'accepted':
        state['stage'] = 'stapling'
        atomic_json(run / 'state.json', state)
    commands.call('staple', ['/usr/bin/xcrun', 'stapler', 'staple', app], timeout=300)
    commands.call('validate-ticket', ['/usr/bin/xcrun', 'stapler', 'validate', app])
    if verify_signatures(commands, app, state) != state['signatures']:
        raise RuntimeError('Signed code identity changed after notarization.')
    commands.call('gatekeeper', ['/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=2', app])
    archive = run / ('PluginAuthDesk-macOS-arm64-v' + state['version'] + '.zip')
    commands.call('distribution-zip', ['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, archive], timeout=300)
    extracted = run / ('verify-' + uuid.uuid4().hex)
    extracted.mkdir()
    commands.call('extract-distribution', ['/usr/bin/ditto', '-x', '-k', archive, extracted], timeout=300)
    verified = extracted / APP_NAME
    if tree_digest(verified) != tree_digest(app):
        raise RuntimeError('The extracted distribution differs from the stapled app.')
    commands.call('validate-extracted-ticket', ['/usr/bin/xcrun', 'stapler', 'validate', verified])
    if verify_signatures(commands, verified, state) != state['signatures']:
        raise RuntimeError('The extracted distribution has different signed code.')
    gatekeeper = commands.call('assess-extracted', ['/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=2', verified])
    if 'source=Notarized Developer ID' not in gatekeeper[0].read_text() + gatekeeper[1].read_text():
        raise RuntimeError('Gatekeeper did not report Notarized Developer ID for the extracted app.')
    digest = sha256(archive)
    archive.with_name(archive.name + '.sha256').write_text(digest + '  ' + archive.name + '\n', encoding='utf-8')
    state.update(stage='complete', archive=archive.name, archive_sha256=digest, final_digest=tree_digest(app))
    atomic_json(run / 'state.json', state)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-app', type=Path, default=ROOT / 'dist' / APP_NAME)
    parser.add_argument('--output-root', type=Path, default=ROOT / 'results/notarization')
    parser.add_argument('--identity', help='Explicit Developer ID Application certificate SHA-1')
    parser.add_argument('--keychain', type=Path, help='Signing keychain; notary credentials use their own default search list')
    parser.add_argument('--profile', help='Existing notarytool Keychain profile name')
    parser.add_argument('--team-id')
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--resume', type=Path)
    parser.add_argument('--submission-id', help='Recover an interrupted upload; never automatically submit it twice')
    args = parser.parse_args(argv)
    os.umask(0o077)
    if args.resume:
        args.resume = args.resume.expanduser()
        if args.resume.is_symlink() or not args.resume.is_dir():
            raise RuntimeError('--resume must be an existing non-symlink run directory.')
        run = args.resume.absolute()
        state = read_json(run / 'state.json')
        for key in ('identity', 'profile', 'team_id', 'keychain'):
            value = getattr(args, key)
            if value is not None and str(value) != state.get(key):
                raise RuntimeError('Resume settings differ from the saved run: ' + key)
    else:
        if args.submission_id:
            raise RuntimeError('--submission-id requires --resume.')
        source = args.source_app.expanduser().absolute()
        version, source_digest = bundle_info(source), tree_digest(source)
        state = dict(schema=1, stage='copying', source=str(source), source_digest=source_digest, version=version,
                     identity=(args.identity or '').upper(), team_id=(args.team_id or '').upper(),
                     profile=args.profile, keychain=str(args.keychain.expanduser().absolute()) if args.keychain else '')
        validate_settings(state)
        output = args.output_root.expanduser().absolute()
        validate_output_root(source, output)
        output.mkdir(parents=True, exist_ok=True)
        run = output / ('run-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex[:8])
        run.mkdir(mode=0o700)
        entitlements = plistlib.loads((ROOT / 'packaging/host-entitlements.plist').read_bytes())
        if entitlements != ENTITLEMENTS:
            raise RuntimeError('Only the reviewed plug-in-host runtime exceptions are allowed.')
        (run / 'host-entitlements.plist').write_bytes(plistlib.dumps(entitlements))
        atomic_json(run / 'state.json', state)
    validate_settings(state)
    print('RUN_DIR=' + str(run), flush=True)
    lock = os.open(run / '.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        commands = Commands(run)
        app = run / APP_NAME
        if state['stage'] in PREPARING:
            prepare(run, state, commands)
        if verify_signatures(commands, app, state) != state['signatures']:
            raise RuntimeError('Prepared signatures changed; never re-sign an already submitted run.')
        expected = state.get('final_digest') if state['stage'] == 'complete' else state['signed_digest']
        if state['stage'] != 'stapling' and tree_digest(app) != expected:
            raise RuntimeError('Prepared app contents changed; preserve the run and start from a new build.')
        if state['stage'] == 'complete':
            if sha256(run / state['archive']) != state['archive_sha256']:
                raise RuntimeError('Completed distribution ZIP changed.')
            print('COMPLETE=' + str(run / state['archive']), flush=True)
            return
        if args.prepare_only:
            print('PREPARED=' + str(app), flush=True)
            return
        if state['stage'] not in {'accepted', 'stapling'}:
            resume_submission(run, state, commands, args.submission_id)
        if state['stage'] not in {'accepted', 'stapling'}:
            raise RuntimeError('Refusing to staple without an Accepted submission.')
        finish(run, state, commands)
        print('COMPLETE=' + str(run / state['archive']), flush=True)
    finally:
        os.close(lock)


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, ValueError, plistlib.InvalidFileException) as error:
        print('ERROR: ' + str(error), file=sys.stderr)
        sys.exit(1)
