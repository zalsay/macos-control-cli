#!/usr/bin/env python3
"""Compile a local smoke host, or prepare a fresh workspace and run it.

Neither mode is invoked by importing this file. Running the host is a GUI/AE
operation and requires the integration owner's separate explicit authorization.
"""
import argparse
import hashlib
import json
import os
import plistlib
import re
from pathlib import Path
import stat
import subprocess
import sys
import uuid

# Reuse the packager's exact namespace, metadata and fixed-resource contracts.
# Do not write module caches into the source tree.
sys.dont_write_bytecode = True
from build import (variant_layout, artifact_paths_for_variant, OBSERVER_REL, OBSERVER_FILES,
                   OBSERVER_STAGE, TEST_APP_STAGE, OBSERVER_PIN_SOURCE, approved_observer_pins, approved_observer_bundle,
                   observer_inputs, validate_metadata, validate_namespace, validate_resources, verify_observer_signing)

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / 'scripts/bound-control-candidate'
STAGE = ROOT / '.build/automation-bound-control-integration-20261104/static-role-20261105/worker-tools'
ROOT_PIN = ROOT / '.build/automation-bound-control-integration-20261104/runtime-root.json'

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for data in iter(lambda: f.read(1048576), b''): h.update(data)
    return h.hexdigest()

def compile_host(variant='legacy'):
    if variant not in ('legacy', 'observer', 'testing'): raise RuntimeError('invalid host variant')
    host_stage = OBSERVER_STAGE if variant == 'observer' else TEST_APP_STAGE if variant == 'testing' else STAGE
    if host_stage.is_symlink() or not host_stage.is_dir(): raise RuntimeError('invalid stage')
    if variant == 'observer':
        approved_observer_pins()
        approved_observer_bundle()
    out = host_stage / ('host-' + uuid.uuid4().hex)
    out.mkdir(mode=0o700)
    (out / 'tmp').mkdir(mode=0o700)
    (out / 'module-cache').mkdir(mode=0o700)
    env = {'PATH':'/usr/bin:/bin:/usr/sbin:/sbin', 'HOME':str(Path.home()),
           'TMPDIR':str(out/'tmp'), 'CLANG_MODULE_CACHE_PATH':str(out/'module-cache'), 'LC_ALL':'C'}
    sources = [TOOLS/'host.h', TOOLS/'host.c', TOOLS/'SwiftHost.swift', TOOLS/'build.py',
               ROOT/'Sources/BinderIdentity/BinderIdentity.c', ROOT/'Sources/BinderIdentity/include/BinderIdentity.h',
               ROOT/'Sources/SafarierCore/AutomationProtocol.swift', ROOT/'Sources/SafarierCore/SPIFeatures.swift', Path(__file__)]
    if variant == 'observer':
        sources += [OBSERVER_PIN_SOURCE, *observer_inputs(), *(approved_observer_bundle()/name for name in OBSERVER_FILES)]
    def snapshot(): return {str(p.relative_to(ROOT)):digest(p) for p in sources}
    before = snapshot()
    (out/'source-before.json').write_text(json.dumps(before, indent=2, sort_keys=True)+'\n')
    include = ROOT/'Sources/BinderIdentity/include'
    embedded_info = out/'host-info.plist'
    with embedded_info.open('xb') as f:
        plistlib.dump({'CFBundleIdentifier':('sh.safarier.testing.smokehost' if variant == 'testing' else 'sh.safarier.boundcandidate.smokehost'),
            'CFBundleName':'Safarier Bound Candidate Smoke Host',
            'CFBundleExecutable':'smoke-host',
            'NSAppleEventsUsageDescription':'仅控制本次 Safarier 本地测试候选。'}, f, sort_keys=True)
    (out/'host-info.sha256').write_text(digest(embedded_info)+'\n')
    cmds = [
        ['/usr/bin/xcrun','clang','-c',str(ROOT/'Sources/BinderIdentity/BinderIdentity.c'),'-I',str(include),'-o',str(out/'binder.o')],
        ['/usr/bin/xcrun','clang','-c',str(TOOLS/'host.c'),'-I',str(include),'-o',str(out/'host.o')],
        ['/usr/bin/xcrun','swiftc','-module-cache-path',str(out/'module-cache'),'-import-objc-header',str(TOOLS/'host.h'),'-I',str(include),
         str(ROOT/'Sources/SafarierCore/AutomationProtocol.swift'),str(ROOT/'Sources/SafarierCore/SPIFeatures.swift'),str(TOOLS/'SwiftHost.swift'),str(out/'binder.o'),str(out/'host.o'),
         '-framework','AppKit','-framework','Carbon','-framework','Security','-lbsm',
         '-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',str(embedded_info),
         '-o',str(out/'smoke-host')]]
    if variant == 'testing':
        cmds[0][2:2] = ['-DSAFARIER_BOUND_LOCAL_CANDIDATE', '-DSAFARIER_INTERNAL_TEST_APP']
        cmds[1][2:2] = ['-DSAFARIER_BOUND_LOCAL_CANDIDATE', '-DSAFARIER_INTERNAL_TEST_APP']
        cmds[2][2:2] = ['-D', 'SAFARIER_BOUND_LOCAL_CANDIDATE', '-D', 'SAFARIER_INTERNAL_TEST_APP']
    if variant == 'observer': cmds[2][2:2] = ['-D', 'SAFARIER_WHEEL_OBSERVER_PROBE']
    (out/'variant.json').write_text(json.dumps({'variant':variant},indent=2)+'\n')
    for i, cmd in enumerate(cmds,1):
        prefix = out / f'command-{i}'
        prefix.with_suffix('.json').write_text(json.dumps({'argv':cmd,'env':env,'cwd':str(ROOT)},indent=2)+'\n')
        with prefix.with_suffix('.stdout').open('xb') as stdout, prefix.with_suffix('.stderr').open('xb') as stderr:
            result = subprocess.run(cmd, cwd=ROOT, env=env, stdout=stdout, stderr=stderr)
        prefix.with_suffix('.exit').write_text(str(result.returncode)+'\n')
        if result.returncode: raise RuntimeError(f'host compile failed; see {prefix}')
    after = snapshot()
    (out/'source-after.json').write_text(json.dumps(after, indent=2, sort_keys=True)+'\n')
    if before != after: raise RuntimeError('host sources changed; reject attempt')
    (out/'smoke-host.sha256').write_text(digest(out/'smoke-host')+'\n')
    print(out/'smoke-host')

def read_root_receipt(path):
    # Walk only within the existing stage, without following any receipt-path symlink.
    candidate = Path(path)
    if not candidate.is_absolute(): candidate = Path.cwd() / candidate
    try:
        relative = candidate.relative_to(ROOT_PIN.parent)
    except ValueError:
        raise RuntimeError('runtime root receipt outside stage')
    parts = relative.parts
    if not parts or any(part in ('.', '..') for part in parts):
        raise RuntimeError('invalid runtime root receipt path')
    directory = os.open(ROOT_PIN.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=directory)
            os.close(directory)
            directory = child
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, dir_fd=directory)
        with os.fdopen(fd, 'r') as f:
            info = os.fstat(f.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
                raise RuntimeError('untrusted runtime root receipt')
            return json.load(f)
    finally:
        os.close(directory)

def run_host(host, app, expected, runner_expected, label, preflight_only, request_consent_once, runtime_root_receipt, scenario, variant='legacy'):
    if variant == 'observer':
        if scenario != 'observer' or preflight_only or request_consent_once: raise RuntimeError('observer host requires probe-only scenario and no consent request')
        receipt_path = Path(runtime_root_receipt)
        if not receipt_path.is_absolute(): receipt_path = Path.cwd() / receipt_path
        try: receipt_path.relative_to(OBSERVER_STAGE.parent)
        except ValueError: raise RuntimeError('observer runtime receipt outside new stage')
        approved_observer_pins()
    elif variant == 'testing':
        if scenario not in ('testing', 'testing-input', 'testing-google') or (scenario in ('testing-input', 'testing-google') and (preflight_only or request_consent_once)) or (request_consent_once and not preflight_only): raise RuntimeError('invalid testing mode')
        receipt_path = Path(runtime_root_receipt)
        if not receipt_path.is_absolute(): receipt_path = Path.cwd() / receipt_path
        try: receipt_path.relative_to(TEST_APP_STAGE.parent)
        except ValueError: raise RuntimeError('testing runtime receipt outside testing stage')
    elif variant != 'legacy' or scenario in ('observer', 'testing', 'testing-input', 'testing-google'): raise RuntimeError('invalid host variant or scenario')
    if variant != 'testing' and preflight_only and request_consent_once: raise RuntimeError('combined preflight and consent is testing-only')
    if scenario == "form-a" and request_consent_once: raise RuntimeError("form-a requires false preflight; consent request is disabled")
    pin = read_root_receipt(runtime_root_receipt)
    root = Path(pin['path'])
    if variant in ('observer', 'testing') and (not root.is_absolute() or root.parent != Path.home().resolve()): raise RuntimeError('observer root must be a new direct home directory')
    st = root.lstat()
    if not stat.S_ISDIR(st.st_mode) or pin['mode']!='0700' or stat.S_IMODE(st.st_mode)!=0o700 or st.st_uid!=os.geteuid() or st.st_uid!=pin['uid'] or st.st_dev!=pin['device'] or st.st_ino!=pin['inode']:
        raise RuntimeError('runtime root identity mismatch')
    app = Path(app)
    layout = variant_layout(variant)
    if app != root/layout['app'] or app.is_symlink() or not app.is_dir(): raise RuntimeError('candidate must match the exact variant runtime-root app leaf')
    validate_namespace(app, variant)
    validate_metadata(app, variant)
    validate_resources(app, variant)
    # These are independent caller-supplied executable pins, not identity grants.
    if digest(app/layout['main_exec']) != expected: raise RuntimeError('Main executable pin mismatch')
    if digest(app/layout['runner_exec']) != runner_expected: raise RuntimeError('Runner executable pin mismatch')
    host = Path(host).resolve(strict=True)
    expected_stage = OBSERVER_STAGE if variant == 'observer' else TEST_APP_STAGE if variant == 'testing' else STAGE
    if host.parent.parent != expected_stage.resolve() or host.name != 'smoke-host' or digest(host)!=(host.parent/'smoke-host.sha256').read_text().strip(): raise RuntimeError('host artifact mismatch')
    marker = host.parent/'variant.json'
    if variant == 'testing' and (not marker.is_file() or json.loads(marker.read_text()).get('variant') != 'testing'): raise RuntimeError('testing host variant mismatch')
    if variant == 'observer' and (not marker.is_file() or json.loads(marker.read_text()).get('variant') != 'observer'): raise RuntimeError('observer host variant mismatch')
    if variant == 'legacy' and marker.is_file() and json.loads(marker.read_text()).get('variant') != 'legacy': raise RuntimeError('legacy host variant mismatch')
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}', label): raise RuntimeError('invalid attempt label')
    attempt = root/label
    attempt.mkdir(mode=0o700)
    results = attempt/'results'
    results.mkdir(mode=0o700)
    (results/'tmp').mkdir(mode=0o700)
    env = {'PATH':'/usr/bin:/bin:/usr/sbin:/sbin', 'HOME':str(Path.home()),
           'TMPDIR':str(results/'tmp'), 'LC_ALL':'C'}
    (results/'environment.json').write_text(json.dumps(env,indent=2)+'\n')
    # This observation is a receipt, not a manifest or a runtime authority.
    artifact_paths = artifact_paths_for_variant(variant)
    artifact_pins = {name:digest(app/name) for name in artifact_paths}
    (results/'artifact-sha256.json').write_text(json.dumps(artifact_pins,indent=2,sort_keys=True)+'\n')
    def verify(name, bundle):
        argv = ['/usr/bin/codesign', '--verify', '--strict', '--verbose=2', str(bundle)]
        (results/(name+'.json')).write_text(json.dumps({'argv':argv,'cwd':str(ROOT),'env':env},indent=2)+'\n')
        with (results/(name+'.stdout')).open('xb') as out, (results/(name+'.stderr')).open('xb') as err:
            result = subprocess.run(argv, stdout=out, stderr=err, cwd=ROOT, env=env)
        (results/(name+'.exit')).write_text(str(result.returncode)+'\n')
        if result.returncode: raise RuntimeError(name+' failed')
    if variant == 'observer':
        def observer_run(argv):
            name = 'verify-observer' if '--verify' in argv else 'observer-signing-info'
            prefix = results/name
            prefix.with_suffix('.json').write_text(json.dumps({'argv':argv,'cwd':str(ROOT),'env':env},indent=2)+'\n')
            with prefix.with_suffix('.stdout').open('xb') as out, prefix.with_suffix('.stderr').open('xb') as err:
                result = subprocess.run(argv, stdout=out, stderr=err, cwd=ROOT, env=env)
            prefix.with_suffix('.exit').write_text(str(result.returncode)+'\n')
            if result.returncode: raise RuntimeError(name+' failed')
            return prefix
        verify_observer_signing(app/layout['runner_rel']/OBSERVER_REL, observer_run, approved_observer_pins())
    verify('verify-runner', app/layout['runner_rel'])
    verify('verify-main', app)
    # Detect changes during preflight; Core still revalidates before operations.
    validate_namespace(app, variant)
    validate_metadata(app, variant)
    validate_resources(app, variant)
    if {name:digest(app/name) for name in artifact_paths} != artifact_pins:
        raise RuntimeError('artifact changed during signature verification')
    # Exclusive workspace: never reuse, chmod, migrate, or remove an existing one.
    workspace = attempt/'workspace'
    workspace.mkdir(mode=0o700)
    (workspace/'locks').mkdir(mode=0o700)
    profile = str(uuid.uuid4())
    document = {'version':1,'records':[{'id':profile,'name':'Bound control ephemeral', 'mode':'ephemeral',
        'createdAt':0, 'languages':[], 'followProxyLanguages':False,'followProxyTimeZone':False,
        'notes':'', 'spi':[], 'allowsBackgroundAutomation':True}]}
    fd = os.open(workspace/'profiles.json', os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd,'w') as f: json.dump(document,f,sort_keys=True); f.write('\n')
    argv = [str(host), str(app), str(workspace), profile, str(results),
            '--wheel-observer-smoke' if variant == 'observer' else '--preflight-only' if preflight_only else '--testing-google' if variant == 'testing' and scenario == 'testing-google' else '--testing-input' if variant == 'testing' and scenario == 'testing-input' else '--testing-smoke' if variant == 'testing' else '--form-a-smoke' if scenario == 'form-a' else '--smoke']
    if request_consent_once: argv.append('--request-consent-once')
    (results/'argv.json').write_text(json.dumps(argv,indent=2)+'\n')
    # No inherited environment dump and no session data on argv or disk.
    with (results/'stdout.jsonl').open('x') as out, (results/'stderr.txt').open('x') as err:
        proc = subprocess.run(argv, stdout=out, stderr=err, cwd=ROOT, env=env)
    (results/'exit').write_text(str(proc.returncode)+'\n')
    if proc.returncode: raise RuntimeError('smoke stopped; inspect redacted status, cleanup may be unconfirmed')

if __name__ == '__main__':
    os.umask(0o077)
    parser=argparse.ArgumentParser()
    sub=parser.add_subparsers(dest='mode',required=True)
    compile_parser=sub.add_parser('compile')
    compile_parser.add_argument('--variant',choices=['legacy','observer','testing'],default='legacy')
    run=sub.add_parser('run')
    run.add_argument('--host',required=True); run.add_argument('--app',required=True)
    run.add_argument('--executable-sha256',required=True)
    run.add_argument('--runner-executable-sha256',required=True)
    run.add_argument('--label',required=True)
    run.add_argument('--runtime-root-receipt',default=str(ROOT_PIN))
    run.add_argument('--scenario',choices=['pointer','form-a','observer','testing','testing-input','testing-google'],default='pointer')
    run.add_argument('--variant',choices=['legacy','observer','testing'],default='legacy')
    run.add_argument('--preflight-only',action='store_true')
    run.add_argument('--request-consent-once',action='store_true')
    args=parser.parse_args()
    try:
        if args.mode=='compile': compile_host(args.variant)
        else: run_host(args.host,args.app,args.executable_sha256,args.runner_executable_sha256,args.label,args.preflight_only,args.request_consent_once,args.runtime_root_receipt,args.scenario,args.variant)
    except Exception as exc:
        print('stopped:',type(exc).__name__,str(exc),file=sys.stderr); sys.exit(1)
