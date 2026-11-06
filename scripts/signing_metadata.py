#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Remove only signing-incompatible Finder metadata from a generated bundle.

Keep quarantine, provenance, and all unrelated extended attributes intact.
Never follow a symlink into another bundle or a user's files.
"""
from pathlib import Path
import subprocess
import sys

SIGNING_METADATA = ('com.apple.FinderInfo', 'com.apple.ResourceFork')


def clear_signing_metadata(bundle):
    bundle = Path(bundle)
    if bundle.is_symlink() or not bundle.is_dir():
        raise RuntimeError('Expected a generated bundle directory, not a symlink.')
    # Validate the complete tree before changing any attribute.
    for path in bundle.rglob('*'):
        if path.is_symlink() or not (path.is_dir() or path.is_file()):
            raise RuntimeError('Refusing a symlink or non-regular entry in the generated bundle.')
    for attribute in SIGNING_METADATA:
        subprocess.run(['/usr/bin/xattr', '-r', '-d', attribute, str(bundle)],
                       check=True, timeout=30)


if __name__ == '__main__':
    try:
        if len(sys.argv) != 2:
            raise RuntimeError('Usage: signing_metadata.py /path/to/generated-bundle')
        clear_signing_metadata(sys.argv[1])
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print('ERROR: ' + str(error), file=sys.stderr)
        sys.exit(1)
