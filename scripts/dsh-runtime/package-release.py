#!/usr/bin/env python3
"""Assemble a reviewed testing candidate and runtime; never install or publish."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

import install
import verify

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('bound_candidate_build', HERE.parent / 'bound-control-candidate/build.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
INSTALLER_FILES = ('install.py', 'verify.py', 'prepare.py')


def read_pins(path):
    def no_duplicates(pairs):
        result = {}
        for key, value in pairs:
            if key in result: raise ValueError('duplicate pin')
            result[key] = value
        return result
    path = Path(path)
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise ValueError('pin file must be an absolute regular file')
    pins = json.loads(path.read_text(), object_pairs_hook=no_duplicates)
    expected = set(build.artifact_paths_for_variant('testing'))
    if not isinstance(pins, dict) or set(pins) != expected or len(expected) != 12:
        raise ValueError('expected exactly twelve testing app pins')
    if any(not isinstance(v, str) or not re.fullmatch(r'[0-9a-f]{64}', v) or not int(v, 16) for v in pins.values()):
        raise ValueError('invalid app pin')
    return pins


def check_app(app, pins):
    build.validate_namespace(app, 'testing')
    build.validate_metadata(app, 'testing')
    build.validate_resources(app, 'testing')
    runner = app / build.variant_layout('testing')['runner_rel']
    for bundle, identifier in ((runner, 'sh.safarier.testing.runner'), (app, 'sh.safarier.testing')):
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '--verbose=2', str(bundle)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        detail = subprocess.run(['/usr/bin/codesign', '-d', '--verbose=4', str(bundle)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stderr.decode('utf-8', 'replace')
        if re.findall(r'^Identifier=(.+)$', detail, re.MULTILINE) != [identifier]:
            raise ValueError('unexpected signing identifier')
    actual = {name: build.sha(app / name) for name in pins}
    if actual != pins: raise ValueError('app pins mismatch')
    build.validate_namespace(app, 'testing')
    if {name: build.sha(app / name) for name in pins} != pins:
        raise ValueError('app changed during verification')


def installer_hashes(root):
    return {name: verify.prepare.digest_file(root/name) for name in INSTALLER_FILES}


def package_release(app, artifact, pinfile, output):
    app, artifact, output = map(Path, (app, artifact, output))
    if not all(p.is_absolute() for p in (app, artifact, output)):
        raise ValueError('all paths must be absolute')
    if output.exists() or output.is_symlink(): raise FileExistsError(str(output))
    if not output.parent.is_dir() or output.resolve().is_relative_to(app.resolve()) or output.resolve().is_relative_to(artifact.resolve()):
        raise ValueError('output must have an existing parent outside inputs')
    pins = read_pins(pinfile)
    anchor = install.required_anchor()
    check_app(app, pins)
    verify.verify_artifact(artifact, anchor.hashes)
    source_installer_hashes = installer_hashes(HERE)
    output.mkdir(mode=0o700)
    (output/'INCOMPLETE').write_text('Packaging incomplete; do not use.\n')
    app_copy = output/'Safarier AI.app'
    shutil.copytree(app, app_copy, symlinks=True)
    artifact_copy = output/'runtime-artifact'; artifact_copy.mkdir(mode=0o700)
    for name in ('manifest.json', 'runtime.dmg', 'review.json'):
        verify.checked_copy(artifact/name, artifact_copy/name, limit=64*1024*1024 if name != 'runtime.dmg' else None)
    installer = output/'installer'; installer.mkdir(mode=0o700)
    for name in INSTALLER_FILES:
        shutil.copyfile(HERE/name, installer/name)
    check_app(app_copy, pins)
    verify.verify_artifact(artifact_copy, anchor.hashes)
    copied_hashes = installer_hashes(installer)
    if copied_hashes != source_installer_hashes or installer_hashes(HERE) != source_installer_hashes:
        raise ValueError('installer source or copy changed')
    instructions = '''Safarier testing candidate - manual sidecar update\n\nThe bundled installer Python files are NOT covered by the App signature. Use installer scripts only from your independently trusted and reviewed repository source, and compare their SHA-256 values with evidence.json and an independently trusted record. evidence.json is a receipt, not a trust anchor.\n\nCreate the following user-private directory only if it does not already exist, and ensure it is owned by you with mode 0700:\n  ~/Library/Application Support/Safarier/DSHRuntime\n\nFrom a trusted reviewed repository checkout, run (replace RELEASE_DIR with this directory):\n  python3 scripts/dsh-runtime/install.py install --artifact "RELEASE_DIR/runtime-artifact" --versions-root "$HOME/Library/Application Support/Safarier/DSHRuntime"\n\nAfter successful sidecar installation, manually replace the App only when appropriate. Do not replace a running App. The DSH_HOME and agents user data are separate and are not changed by this packaging tool.\n\nThis is a testing candidate, not a published release. Installer/runtime execution and App integration require independent review and acceptance.\n'''
    (output/'INSTALL.txt').write_text(instructions)
    evidence = {'variant':'testing', 'app_pins':pins, 'installer_sha256':copied_hashes,
                'runtime': {'manifest_sha256':anchor.manifest_sha256, 'image_sha256':anchor.image_sha256, 'node_version':anchor.node_version},
                'trust':'receipt only; compare with independent reviewed records'}
    (output/'evidence.json').write_text(json.dumps(evidence, indent=2, sort_keys=True)+'\n')
    (output/'INCOMPLETE').unlink()
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('app', 'artifact', 'app-pins', 'output'): parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    print('Testing candidate assembled (not installed or published):', package_release(args.app, args.artifact, args.app_pins, args.output))

if __name__ == '__main__': main()
