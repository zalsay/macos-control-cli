#!/usr/bin/env python3
"""Prepare one unsigned-source, ad-hoc-signed local candidate; never launch it.

Run only after the integration owner approves the exact source snapshot. Each
invocation creates a new stage attempt and refuses to overwrite existing paths.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
STAGE = ROOT / '.build/automation-bound-control-integration-20261104/static-role-20261105/worker-tools'
TEST_APP_STAGE = ROOT / '.build/automation-bound-control-integration-20261104/formal-test-app-20261106-001/packaging'
FIXTURE = ROOT / 'scripts/background-input-probe/fixture.html'
SDEF = ROOT / 'Sources/Safarier/Resources/Safarier.sdef'
ICON = ROOT / 'scripts/bound-control-candidate/resources/AppIcon.icns'
ICON_SOURCE = ROOT / 'scripts/make-icon.swift'
ICON_SOURCE_SHA256 = 'd082f2ef1cc08fe30a4d38ce1e647074136fd571333851f55a02af8f3d6b4dcf'
ICON_PATH = 'Contents/Resources/AppIcon.icns'
ICON_SHA256 = 'ae937f29c597080775e53a52c8337aa5e0dc1d268a8b26ad25ec193c2e7d374c'
# testing 候选自带的 mihomo（Clash 订阅节点用）：输入是已 ad-hoc 签名的固定文件（codesign 会改写字节，
# 所以 pin 的是签名后形态；本机已验证同参数签名是字节可复现的）。哈希要和 Swift 侧
# Sources/SafarierCore/BundleResourcePin.swift 的 localCandidate 契约一致，换二进制时两处一起审核更新。
MIHOMO_REL = 'Contents/Helpers/mihomo'
MIHOMO_ID = 'sh.safarier.mihomo'
MIHOMO_SOURCE = ROOT / '.build/mihomo/mihomo-signed'
ATTEMPT = None
EXPECTED = {
    'fixture': '45f599bd8d943192d3f93045559a825b8922f5b2df8106393fc896394355edc1',
    'sdef': '0cb1c89e68376982342c0a4821b8f9a719d99e4ceb5b476e5ec748e773b5890c',
    'mihomo': '3ebf3ac4c7f63764cd9e6174cd024b100236eb4c9252e2541f4416cb109ceda5',
}

RUNNER_REL = 'Contents/Helpers/SafarierRunner.app'
RUNNER_EXEC = RUNNER_REL + '/Contents/MacOS/SafarierRunner'
RUNNER_NAMESPACE = {
    'Contents', 'Contents/Info.plist', 'Contents/MacOS', 'Contents/MacOS/SafarierRunner',
    'Contents/Resources', 'Contents/Resources/control-fixture.html',
    'Contents/_CodeSignature', 'Contents/_CodeSignature/CodeResources',
}
MAIN_BASE_NAMESPACE = {
    'Contents', 'Contents/Info.plist', 'Contents/MacOS', 'Contents/MacOS/Safarier',
    'Contents/Resources', 'Contents/Resources/Safarier.sdef', 'Contents/Resources/control-fixture.html',
    'Contents/_CodeSignature', 'Contents/_CodeSignature/CodeResources',
}
MAIN_NAMESPACE = MAIN_BASE_NAMESPACE | {'Contents/Helpers', RUNNER_REL} | {RUNNER_REL + '/' + p for p in RUNNER_NAMESPACE}
# Static review inputs, never recovered from a target bundle or generated receipt.
# Main must fill these after independently reviewing the signed prebuild.
OBSERVER_BID = 'sh.safarier.boundcandidate.wheelobserver'
OBSERVER_LEAF = 'SafarierWheelObserver'
OBSERVER_REL = 'Contents/PlugIns/SafarierWheelObserver.bundle'
OBSERVER_SOURCE = ROOT / 'scripts/bound-control-candidate/observer/SafarierWheelObserver.m'
OBSERVER_SOURCE_DIR = OBSERVER_SOURCE.parent
OBSERVER_STAGE = ROOT / '.build/automation-bound-control-integration-20261104/wheel-observer-20261105-001/packaging'
OBSERVER_PIN_SOURCE = ROOT / 'Sources/SafarierCore/BoundWheelObserverArtifactPin.swift'
OBSERVER_APPROVED_BUNDLE = '/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-observer-20261105-001/packaging/observer-prebuild-20261105-194911-bdc5f56b24a34a429b44c9295d0c4245/SafarierWheelObserver.bundle'
OBSERVER_APPROVED_PINS = {'info': '431b24f94893c8693306f0ab2865e0824efd41f7faf7caca43963dfcff2c5ac5', 'executable': '0919ecd276236c98a448e2c37150773040f452201e0c33d3c4cb052f854d7713', 'resources': '6686de10a28a2fe11b36cbb86dcbacc827cfc4ea116b4dabf1845e5aee629e9b', 'cdhash': '29d07339c8f3c267515012a3e06b3c8e2fa6846a', 'swiftPinSource': '6ffd60be32aaadc6453abdb1c4775ef92f6c0274f75f688bc20cd6702214e2ce'}
OBSERVER_NAMESPACE = {
    'Contents', 'Contents/Info.plist', 'Contents/MacOS', 'Contents/MacOS/' + OBSERVER_LEAF,
    'Contents/_CodeSignature', 'Contents/_CodeSignature/CodeResources',
}
OBSERVER_FILES = ('Contents/Info.plist', 'Contents/MacOS/' + OBSERVER_LEAF,
                  'Contents/_CodeSignature/CodeResources')

ARTIFACT_PATHS = (
    'Contents/Info.plist', 'Contents/MacOS/Safarier', 'Contents/_CodeSignature/CodeResources',
    'Contents/Resources/Safarier.sdef', 'Contents/Resources/control-fixture.html',
    RUNNER_REL + '/Contents/Info.plist', RUNNER_EXEC,
    RUNNER_REL + '/Contents/_CodeSignature/CodeResources', RUNNER_REL + '/Contents/Resources/control-fixture.html',
)

def variant_layout(variant):
    if variant not in ('legacy', 'observer', 'testing'): raise ValueError('unknown variant')
    main = 'Safarier AI' if variant == 'testing' else 'Safarier'
    runner = 'Safarier AI Browser' if variant == 'testing' else 'SafarierRunner'
    runner_rel = 'Contents/Helpers/' + runner + '.app'
    return dict(app=main + '.app', main_leaf=main, runner_leaf=runner,
                main_exec='Contents/MacOS/' + main, runner_rel=runner_rel,
                runner_exec=runner_rel + '/Contents/MacOS/' + runner)

def testing_path(path):
    # Exact reviewed path components, not a fallback accepted from a bundle.
    names = {'Safarier': 'Safarier AI', 'SafarierRunner': 'Safarier AI Browser',
             'SafarierRunner.app': 'Safarier AI Browser.app'}
    return '/'.join(names.get(part, part) for part in path.split('/'))

def artifact_paths_for_variant(variant):
    layout = variant_layout(variant)
    if variant == 'testing':
        return tuple(testing_path(p) for p in ARTIFACT_PATHS) + (ICON_PATH, layout['runner_rel'] + '/' + ICON_PATH, MIHOMO_REL)
    if variant == 'observer':
        return ARTIFACT_PATHS + tuple(RUNNER_REL + '/' + OBSERVER_REL + '/' + name for name in OBSERVER_FILES)
    return ARTIFACT_PATHS

def namespaces_for_variant(variant):
    if variant == 'legacy': return MAIN_NAMESPACE, RUNNER_NAMESPACE
    if variant == 'testing': return {testing_path(p) for p in MAIN_NAMESPACE} | {ICON_PATH, variant_layout(variant)['runner_rel'] + '/' + ICON_PATH, MIHOMO_REL}, {testing_path(p) for p in RUNNER_NAMESPACE} | {ICON_PATH}
    if variant != 'observer': raise ValueError('unknown variant')
    runner = RUNNER_NAMESPACE | {'Contents/PlugIns', OBSERVER_REL} | {OBSERVER_REL + '/' + p for p in OBSERVER_NAMESPACE}
    parent = MAIN_BASE_NAMESPACE | {'Contents/Helpers', RUNNER_REL} | {RUNNER_REL + '/' + p for p in runner}
    return parent, runner

def approved_observer_pins():
    pins = OBSERVER_APPROVED_PINS
    if not isinstance(pins, dict) or set(pins) != {'info', 'executable', 'resources', 'cdhash', 'swiftPinSource'}:
        raise RuntimeError('observer pins are not preapproved')
    for key in ('info', 'executable', 'resources', 'swiftPinSource'):
        if not isinstance(pins[key], str) or len(pins[key]) != 64 or set(pins[key]) - set('0123456789abcdef') or not int(pins[key], 16):
            raise RuntimeError('invalid fixed observer hash')
    if not isinstance(pins['cdhash'], str) or len(pins['cdhash']) not in (40, 64) or set(pins['cdhash']) - set('0123456789abcdef') or not int(pins['cdhash'], 16):
        raise RuntimeError('invalid fixed observer cdhash')
    if sha(OBSERVER_PIN_SOURCE) != pins['swiftPinSource']:
        raise RuntimeError('observer Swift pin source mismatch')
    return pins

def observer_inputs():
    if not OBSERVER_SOURCE_DIR.is_dir() or OBSERVER_SOURCE_DIR.is_symlink() or not OBSERVER_SOURCE.is_file() or OBSERVER_SOURCE.is_symlink():
        raise RuntimeError('observer source not available')
    entries = sorted(OBSERVER_SOURCE_DIR.iterdir())
    if any(p.is_symlink() or not p.is_file() or p.suffix not in ('.m', '.h') for p in entries):
        raise RuntimeError('invalid observer source namespace')
    if [p for p in entries if p.suffix == '.m'] != [OBSERVER_SOURCE]:
        raise RuntimeError('observer source namespace mismatch')
    return entries

def validate_observer_bundle(bundle, pins):
    if bundle.is_symlink() or not bundle.is_dir(): raise RuntimeError('invalid observer root')
    entries = list(bundle.rglob('*'))
    if {str(p.relative_to(bundle)) for p in entries} != OBSERVER_NAMESPACE:
        raise RuntimeError('observer namespace mismatch')
    for p in entries:
        st = p.lstat()
        if p.is_symlink() or not (stat.S_ISDIR(st.st_mode) or (stat.S_ISREG(st.st_mode) and st.st_nlink == 1)):
            raise RuntimeError('invalid observer object')
    with (bundle/'Contents/Info.plist').open('rb') as f: info = plistlib.load(f)
    if info.get('CFBundleIdentifier') != OBSERVER_BID or info.get('CFBundleExecutable') != OBSERVER_LEAF or info.get('CFBundlePackageType') != 'BNDL':
        raise RuntimeError('invalid observer metadata')
    executable = bundle/'Contents/MacOS'/OBSERVER_LEAF
    with executable.open('rb') as f: header = f.read(32)
    if len(header) != 32:
        raise RuntimeError('short observer Mach-O')
    magic, cpu, _, filetype = struct.unpack('<IIII', header[:16])
    if magic != 0xfeedfacf or cpu != 0x0100000c or filetype != 8:
        raise RuntimeError('observer must be thin arm64 MH_BUNDLE')
    actual = [sha(bundle/name) for name in OBSERVER_FILES]
    if actual != [pins['info'], pins['executable'], pins['resources']]:
        raise RuntimeError('observer approved file hash mismatch')

def verify_observer_signing(bundle, run, pins):
    run(['/usr/bin/codesign', '--verify', '--strict', '--verbose=2', str(bundle)])
    details = run(['/usr/bin/codesign', '-d', '--verbose=4', str(bundle)])
    text = details.with_suffix('.stderr').read_text(errors='replace')
    found = re.findall(r'^CDHash=([0-9a-f]+)$', text, flags=re.MULTILINE)
    identifiers = re.findall(r'^Identifier=(.+)$', text, flags=re.MULTILINE)
    if identifiers != [OBSERVER_BID] or len(found) != 1 or found[0] != pins['cdhash']:
        raise RuntimeError('observer signed identifier or code hash mismatch')

def approved_observer_bundle():
    if not isinstance(OBSERVER_APPROVED_BUNDLE, str): raise RuntimeError('observer bundle not preapproved')
    path = Path(OBSERVER_APPROVED_BUNDLE)
    if not path.is_absolute() or path.is_symlink() or path.resolve(strict=True) != path:
        raise RuntimeError('invalid preapproved observer locator')
    if OBSERVER_STAGE.resolve() not in path.parents:
        raise RuntimeError('observer prebuild outside private stage')
    pins = approved_observer_pins()
    validate_observer_bundle(path, pins)
    return path

def validate_namespace(app, variant='legacy'):
    layout = variant_layout(variant)
    runner = app / layout['runner_rel']
    if app.is_symlink() or runner.is_symlink() or not app.is_dir() or not runner.is_dir():
        raise RuntimeError('invalid bundle root')
    main_namespace, runner_namespace = namespaces_for_variant(variant)
    for root, expected in ((app, main_namespace), (runner, runner_namespace)):
        entries = list(root.rglob('*'))
        actual = {str(p.relative_to(root)) for p in entries}
        if actual != expected or any(p.is_symlink() for p in entries):
            raise RuntimeError('candidate namespace mismatch')
        for p in entries:
            mode = p.lstat().st_mode
            if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
                raise RuntimeError('unexpected bundle object')
    first = (app / layout['main_exec']).lstat()
    second = (app / layout['runner_exec']).lstat()
    if not stat.S_ISREG(first.st_mode) or not stat.S_ISREG(second.st_mode) or first.st_nlink != 1 or second.st_nlink != 1 or (first.st_dev, first.st_ino) == (second.st_dev, second.st_ino):
        raise RuntimeError('executables must be independent regular files')

AUTHORIZATION_USAGE = 'Safarier AI 需要自动化权限，以便按照你的指令控制其他应用。'

def validate_metadata(app, variant='legacy'):
    layout = variant_layout(variant)
    with (app / 'Contents/Info.plist').open('rb') as f: main = plistlib.load(f)
    with (app / layout['runner_rel'] / 'Contents/Info.plist').open('rb') as f: runner = plistlib.load(f)
    main_bid = 'sh.safarier.testing' if variant == 'testing' else 'sh.safarier.boundcandidate'
    runner_bid = 'sh.safarier.testing.runner' if variant == 'testing' else 'sh.safarier.boundcandidate.runner'
    if variant == 'testing' and (any(info.get(key) != leaf for info, leaf in ((main, layout['main_leaf']), (runner, layout['runner_leaf'])) for key in ('CFBundleName', 'CFBundleDisplayName')) or main.get('CFBundleIconFile') != 'AppIcon' or runner.get('CFBundleIconFile') != 'AppIcon'): raise RuntimeError('invalid testing metadata')
    if variant == 'testing' and main.get('NSAppleEventsUsageDescription') != AUTHORIZATION_USAGE:
        raise RuntimeError('invalid authorization usage description')
    if (main.get('CFBundleIdentifier') != main_bid or main.get('CFBundleExecutable') != layout['main_leaf']
            or main.get('CFBundlePackageType') != 'APPL' or main.get('LSUIElement') is not True
            or main.get('NSAppleScriptEnabled') is not True or main.get('OSAScriptingDefinition') != 'Safarier.sdef'):
        raise RuntimeError('invalid Main metadata')
    if (runner.get('CFBundleIdentifier') != runner_bid or runner.get('CFBundleExecutable') != layout['runner_leaf']
            or runner.get('CFBundlePackageType') != 'APPL' or runner.get('LSUIElement') is not True
            or runner.get('NSAppleScriptEnabled') is not False or 'OSAScriptingDefinition' in runner
            or any(key in runner for key in ('CFBundleURLTypes', 'CFBundleDocumentTypes', 'UTExportedTypeDeclarations', 'UTImportedTypeDeclarations'))):
        raise RuntimeError('invalid Runner metadata')
    if variant == 'observer': validate_observer_bundle(app / layout['runner_rel'] / OBSERVER_REL, approved_observer_pins())
    elif variant not in ('legacy', 'testing'): raise ValueError('unknown variant')

def validate_resources(app, variant='legacy'):
    layout = variant_layout(variant)
    if (sha(app / 'Contents/Resources/Safarier.sdef') != EXPECTED['sdef']
            or sha(app / 'Contents/Resources/control-fixture.html') != EXPECTED['fixture']
            or sha(app / layout['runner_rel'] / 'Contents/Resources/control-fixture.html') != EXPECTED['fixture']):
        raise RuntimeError('fixed resource hash mismatch')
    if variant == 'testing' and (sha(app / ICON_PATH) != ICON_SHA256 or sha(app / layout['runner_rel'] / ICON_PATH) != ICON_SHA256):
        raise RuntimeError('fixed icon hash mismatch')
    if variant == 'testing':
        mihomo = app / MIHOMO_REL
        if mihomo.is_symlink() or not mihomo.is_file() or sha(mihomo) != EXPECTED['mihomo']:
            raise RuntimeError('fixed mihomo hash mismatch')

def stage_mihomo(app, run):
    # Only the reviewed binary with the reviewed hash may enter the candidate; never overwrite.
    source, target = MIHOMO_SOURCE, app / MIHOMO_REL
    if source.is_symlink() or not source.is_file():
        raise RuntimeError('missing pinned mihomo input')
    if sha(source) != EXPECTED['mihomo']:
        raise RuntimeError('pinned mihomo hash mismatch')
    if target.exists() or target.is_symlink():
        raise RuntimeError('mihomo target already exists')
    shutil.copyfile(source, target)
    os.chmod(target, 0o755)
    run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', MIHOMO_ID, str(target)])
    run(['/usr/bin/codesign', '--verify', '--strict', '--verbose=2', str(target)])

def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def validate_icon_source():
    # The reviewed generated resource and its design source are a fixed pair.
    # Regenerate via make-icon.swift + sips + iconutil and review both pins.
    if sha(ICON_SOURCE) != ICON_SOURCE_SHA256:
        raise RuntimeError('icon design source changed; regenerate and review the fixed icon pins')
    if sha(ICON) != ICON_SHA256:
        raise RuntimeError('fixed icon source hash mismatch')

def source_inventory(variant='legacy'):
    paths = [ROOT / 'Package.swift', ROOT / 'scripts/build-app.sh', FIXTURE,
             Path(__file__).resolve()]
    paths += sorted(p for p in (ROOT / 'Sources').rglob('*') if p.is_file())
    if variant == 'testing':
        paths += [ICON, ICON_SOURCE]
    elif variant == 'observer':
        paths += observer_inputs()
        plugin = approved_observer_bundle()
        paths += [plugin / name for name in OBSERVER_FILES]
    elif variant not in ('legacy', 'testing'): raise ValueError('unknown variant')
    if (ROOT / 'Package.resolved').exists():
        paths.append(ROOT / 'Package.resolved')
    return {str(p.relative_to(ROOT)): sha(p) for p in paths}

def build_inputs(attempt, variant, configuration):
    if configuration not in ('debug', 'release'):
        raise ValueError('invalid build configuration')
    if configuration == 'release' and variant != 'testing':
        raise ValueError('release configuration is testing-only')
    command = ['/usr/bin/xcrun', 'swift', 'build', '--product', 'Safarier',
        '--configuration', configuration,
        '--scratch-path', attempt / 'scratch', '--cache-path', attempt / 'cache',
        '--config-path', attempt / 'config', '--security-path', attempt / 'security',
        '--disable-dependency-cache', '--manifest-cache', 'local',
        '-Xswiftc', '-D', '-Xswiftc', 'SAFARIER_BOUND_LOCAL_CANDIDATE']
    if variant == 'testing':
        command += ['-Xswiftc', '-D', '-Xswiftc', 'SAFARIER_INTERNAL_TEST_APP']
    if variant == 'observer':
        command += ['-Xswiftc', '-D', '-Xswiftc', 'SAFARIER_WHEEL_OBSERVER_PROBE',
                    '-Xcc', '-DSAFARIER_WHEEL_OBSERVER_PROBE',
                    '-Xswiftc', '-Xcc', '-Xswiftc', '-DSAFARIER_WHEEL_OBSERVER_PROBE']
    return command, attempt / 'scratch' / configuration / 'Safarier'

def main(variant='legacy', configuration='debug'):
    build_inputs(Path('/unused'), variant, configuration)
    stage = OBSERVER_STAGE if variant == 'observer' else TEST_APP_STAGE if variant == 'testing' else STAGE
    if not stage.is_dir() or stage.is_symlink():
        raise RuntimeError('stage worker-tools must already exist and be a directory')
    global ATTEMPT
    attempt = stage / ('attempt-' + time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex)
    attempt.mkdir(mode=0o700)  # exclusive; no cleanup on failure
    ATTEMPT = attempt
    os.umask(0o077)
    (attempt / 'commands').mkdir()
    for name in ('scratch', 'cache', 'tmp', 'config', 'security', 'clang-cache', 'module-cache'):
        (attempt / name).mkdir()
    if (ROOT / '.build/repositories').is_dir():
        shutil.copytree(ROOT / '.build/repositories', attempt / 'cache' / 'repositories')
        shutil.copytree(ROOT / '.build/repositories', attempt / 'scratch' / 'repositories')
    # No inherited secrets or ambient package/cache overrides are recorded or passed.
    env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(Path.home()),
           'TMPDIR': str(attempt / 'tmp'), 'XDG_CACHE_HOME': str(attempt / 'cache'),
           'XDG_CONFIG_HOME': str(attempt / 'config'),
           'CLANG_MODULE_CACHE_PATH': str(attempt / 'clang-cache'),
           'SWIFTPM_MODULECACHE_OVERRIDE': str(attempt / 'module-cache'),
           'LC_ALL': 'C'}
    (attempt / 'environment.json').write_text(json.dumps(env, indent=2) + '\n')
    (attempt / 'build-configuration.json').write_text(json.dumps({'variant': variant, 'configuration': configuration}, indent=2) + '\n')
    before = source_inventory(variant)
    (attempt / 'source-before.json').write_text(json.dumps(before, indent=2, sort_keys=True) + '\n')
    if variant == 'testing':
        validate_icon_source()
    if sha(FIXTURE) != EXPECTED['fixture'] or sha(SDEF) != EXPECTED['sdef']:
        raise RuntimeError('fixed fixture/sdef hash mismatch')
    counter = 0
    def run(argv, extra=None):
        nonlocal counter
        counter += 1
        prefix = attempt / 'commands' / f'{counter:02d}'
        actual_env = dict(env)
        if extra:
            actual_env.update(extra)
        prefix.with_suffix('.json').write_text(json.dumps({'argv': list(map(str, argv)),
            'cwd': str(ROOT), 'env': actual_env}, indent=2) + '\n')
        with prefix.with_suffix('.stdout').open('xb') as out, prefix.with_suffix('.stderr').open('xb') as err:
            try:
                result = subprocess.run(list(map(str, argv)), cwd=ROOT, env=actual_env, stdout=out, stderr=err)
                code = result.returncode
            except OSError:
                code = 127
                raise
            finally:
                prefix.with_suffix('.exit').write_text(str(code) + '\n')
        if code != 0:
            raise RuntimeError(f'command {counter} failed: {code}')
        return prefix
    layout = variant_layout(variant)
    app = attempt / layout['app']
    build_command, built_binary = build_inputs(attempt, variant, configuration)
    run(build_command)
    after = source_inventory(variant)
    (attempt / 'source-after.json').write_text(json.dumps(after, indent=2, sort_keys=True) + '\n')
    if before != after:
        raise RuntimeError('source changed during build; discard this attempt without deleting it')
    run(['/bin/bash', ROOT / 'scripts/build-app.sh'], {'SAFARIER_METADATA_ONLY': '1',
        'SAFARIER_SCRIPTING_CANDIDATE': '1', 'SAFARIER_APP_OUT': str(app),
        'SAFARIER_VERSION': '1.0.1', 'SAFARIER_BUILD': '1'})
    plist_path = app / 'Contents/Info.plist'
    with plist_path.open('rb') as f: info = plistlib.load(f)
    main_bid = 'sh.safarier.testing' if variant == 'testing' else 'sh.safarier.boundcandidate'
    runner_bid = 'sh.safarier.testing.runner' if variant == 'testing' else 'sh.safarier.boundcandidate.runner'
    info.update(CFBundleIdentifier=main_bid, CFBundleExecutable=layout['main_leaf'], LSUIElement=True)
    if variant == 'testing': info.update(CFBundleDisplayName=layout['main_leaf'], CFBundleName=layout['main_leaf'], NSAppleEventsUsageDescription=AUTHORIZATION_USAGE)
    for key in ('CFBundleIconFile', 'CFBundleIconName', 'CFBundleIcons', 'CFBundleURLTypes', 'CFBundleDocumentTypes', 'UTExportedTypeDeclarations', 'UTImportedTypeDeclarations'):
        info.pop(key, None)
    if variant == 'testing': info['CFBundleIconFile'] = 'AppIcon'
    if info.get('NSAppleScriptEnabled') is not True or info.get('OSAScriptingDefinition') != 'Safarier.sdef':
        raise RuntimeError('scripting metadata missing')
    with plist_path.open('wb') as f: plistlib.dump(info, f, sort_keys=True)
    macos = app / 'Contents/MacOS'
    macos.mkdir()
    shutil.copy2(built_binary, macos / layout['main_leaf'])
    shutil.copyfile(FIXTURE, app / 'Contents/Resources/control-fixture.html')
    if sha(app / 'Contents/Resources/Safarier.sdef') != EXPECTED['sdef'] or sha(app / 'Contents/Resources/control-fixture.html') != EXPECTED['fixture']:
        raise RuntimeError('copied resource hash mismatch')
    helper = app / layout['runner_rel']
    (app / 'Contents/Helpers').mkdir()
    helper.mkdir()  # no pre-existing bundle may be overwritten
    (helper / 'Contents').mkdir()
    (helper / 'Contents/MacOS').mkdir()
    (helper / 'Contents/Resources').mkdir()
    helper_info = {
        'CFBundleIdentifier': runner_bid, 'CFBundleExecutable': layout['runner_leaf'],
        'CFBundleName': 'SafarierRunner', 'CFBundleDisplayName': 'Safarier Runner',
        'CFBundlePackageType': 'APPL', 'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleShortVersionString': '1.0.1', 'CFBundleVersion': '1',
        'CFBundleDevelopmentRegion': 'zh-Hans', 'LSMinimumSystemVersion': '14.0',
        'LSUIElement': True, 'NSAppleScriptEnabled': False, 'NSPrincipalClass': 'NSApplication',
    }
    if variant == 'testing':
        helper_info.update(CFBundleName=layout['runner_leaf'], CFBundleDisplayName=layout['runner_leaf'])
        helper_info['CFBundleIconFile'] = 'AppIcon'
        shutil.copyfile(ICON, app / ICON_PATH)
        shutil.copyfile(ICON, helper / ICON_PATH)
    with (helper / 'Contents/Info.plist').open('xb') as f: plistlib.dump(helper_info, f, sort_keys=True)
    shutil.copy2(built_binary, helper / ('Contents/MacOS/' + layout['runner_leaf']))
    shutil.copyfile(FIXTURE, helper / 'Contents/Resources/control-fixture.html')
    if variant == 'testing':
        # 嵌套的 Clash 内核先签，App 本身最后签，和 build-app.sh 的顺序一致。
        stage_mihomo(app, run)
    if variant == 'observer':
        plugin = approved_observer_bundle()
        (helper / 'Contents/PlugIns').mkdir()
        shutil.copytree(plugin, helper / OBSERVER_REL, symlinks=False)
        validate_observer_bundle(helper / OBSERVER_REL, approved_observer_pins())
        verify_observer_signing(helper / OBSERVER_REL, run, approved_observer_pins())
    run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', runner_bid, str(helper)])
    run(['/usr/bin/codesign', '--verify', '--strict', '--verbose=2', str(helper)])
    run(['/usr/bin/codesign', '-d', '--verbose=4', str(helper)])
    run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', main_bid, str(app)])
    run(['/usr/bin/codesign', '--verify', '--strict', '--verbose=2', str(app)])
    run(['/usr/bin/codesign', '-d', '--verbose=4', str(app)])
    run(['/usr/bin/codesign', '--verify', '--strict', '--verbose=2', str(helper)])
    validate_namespace(app, variant)
    validate_metadata(app, variant)
    if variant == 'observer': verify_observer_signing(helper / OBSERVER_REL, run, approved_observer_pins())
    validate_resources(app, variant)
    if source_inventory(variant) != before:
        raise RuntimeError('source changed during packaging; discard this attempt without deleting it')
    paths = artifact_paths_for_variant(variant)
    pin = {name: sha(app / name) for name in paths}
    (attempt / 'candidate-sha256.json').write_text(json.dumps(pin, indent=2, sort_keys=True) + '\n')
    print('Candidate prepared (not launched):', app)
    print('Pin and review independently before copying to the authorized runtime root.')
    return 0

def observer_only():
    # Evidence-generation stage only: the resulting receipt is never authority.
    global ATTEMPT
    if not OBSERVER_STAGE.is_dir() or OBSERVER_STAGE.is_symlink(): raise RuntimeError('observer stage missing')
    sources = observer_inputs()
    attempt = OBSERVER_STAGE / ('observer-prebuild-' + time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex)
    attempt.mkdir(mode=0o700)
    ATTEMPT = attempt
    for name in ('tmp', 'module-cache', 'commands'): (attempt/name).mkdir(mode=0o700)
    env = {'PATH':'/usr/bin:/bin:/usr/sbin:/sbin', 'HOME':str(Path.home()), 'TMPDIR':str(attempt/'tmp'),
           'CLANG_MODULE_CACHE_PATH':str(attempt/'module-cache'), 'LC_ALL':'C'}
    (attempt/'environment.json').write_text(json.dumps(env, indent=2) + '\n')
    def source_snapshot():
        return {str(p.relative_to(ROOT)):sha(p) for p in [Path(__file__).resolve(), *observer_inputs()]}
    before = source_snapshot()
    (attempt/'source-before.json').write_text(json.dumps(before, indent=2, sort_keys=True)+'\n')
    counter = 0
    def run(argv):
        nonlocal counter
        counter += 1
        prefix = attempt/'commands'/f'{counter:02d}'
        (prefix.with_suffix('.json')).write_text(json.dumps({'argv':list(map(str,argv)),'cwd':str(ROOT),'env':env},indent=2)+'\n')
        with prefix.with_suffix('.stdout').open('xb') as out, prefix.with_suffix('.stderr').open('xb') as err:
            result = subprocess.run(list(map(str,argv)), cwd=ROOT, env=env, stdout=out, stderr=err)
        prefix.with_suffix('.exit').write_text(str(result.returncode)+'\n')
        if result.returncode: raise RuntimeError('observer prebuild command failed')
        return prefix
    bundle=attempt/'SafarierWheelObserver.bundle'
    (bundle/'Contents/MacOS').mkdir(parents=True)
    info={'CFBundleIdentifier':OBSERVER_BID,'CFBundleExecutable':OBSERVER_LEAF,
          'CFBundleName':OBSERVER_LEAF,'CFBundlePackageType':'BNDL','CFBundleInfoDictionaryVersion':'6.0'}
    with (bundle/'Contents/Info.plist').open('xb') as f: plistlib.dump(info,f,sort_keys=True)
    run(['/usr/bin/xcrun','clang','-bundle','-fobjc-arc','-I',OBSERVER_SOURCE_DIR,
         OBSERVER_SOURCE,'-framework','Foundation','-framework','WebKit','-o',bundle/'Contents/MacOS'/OBSERVER_LEAF])
    run(['/usr/bin/codesign','--force','--sign','-','--identifier',OBSERVER_BID,str(bundle)])
    run(['/usr/bin/codesign','--verify','--strict','--verbose=2',str(bundle)])
    details=run(['/usr/bin/codesign','-d','--verbose=4',str(bundle)])
    signing=details.with_suffix('.stderr').read_text(errors='replace')
    matches=re.findall(r'^CDHash=([0-9a-f]+)$',signing,flags=re.MULTILINE)
    identifiers=re.findall(r'^Identifier=(.+)$',signing,flags=re.MULTILINE)
    if identifiers!=[OBSERVER_BID] or len(matches)!=1: raise RuntimeError('observer prebuild identifier or cdhash mismatch')
    receipt={'info':sha(bundle/OBSERVER_FILES[0]),'executable':sha(bundle/OBSERVER_FILES[1]),
             'resources':sha(bundle/OBSERVER_FILES[2]),'cdhash':matches[0]}
    validate_observer_bundle(bundle, receipt)
    after=source_snapshot()
    (attempt/'source-after.json').write_text(json.dumps(after,indent=2,sort_keys=True)+'\n')
    if before!=after: raise RuntimeError('observer source changed during prebuild')
    (attempt/'candidate-receipt.json').write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
    print('Observer prebuild only; independent review required:',bundle)
    return 0

if __name__ == '__main__':
    try:
        parser = argparse.ArgumentParser()
        parser.add_argument('--variant', choices=('legacy', 'observer', 'testing'), default='legacy')
        parser.add_argument('--configuration', choices=('debug', 'release'), default='debug')
        parser.add_argument('--observer-only', action='store_true')
        args = parser.parse_args()
        if args.observer_only and (args.variant != 'observer' or args.configuration != 'debug'): raise RuntimeError('observer-only requires debug observer variant')
        code = observer_only() if args.observer_only else main(args.variant, args.configuration)
        if ATTEMPT is not None:
            (ATTEMPT / 'exit').write_text(str(code) + '\n')
        sys.exit(code)
    except Exception as exc:
        message = f'Build stopped: {type(exc).__name__}: {exc}'
        if ATTEMPT is not None:
            (ATTEMPT / 'error.txt').write_text(message + '\n')
            (ATTEMPT / 'exit').write_text('1\n')
        print(message, file=sys.stderr)
        sys.exit(1)
