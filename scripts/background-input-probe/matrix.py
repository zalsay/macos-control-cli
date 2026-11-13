#!/usr/bin/env python3
"""Explicitly gated diagnostic matrix and non-GUI G0 preflight."""
import argparse, datetime, json, os, pathlib, re, subprocess, sys, tempfile, time

p = argparse.ArgumentParser()
modes = p.add_mutually_exclusive_group(required=True)
modes.add_argument('--preflight', action='store_true')
modes.add_argument('--isolated-ui', action='store_true', help='operator confirms an isolated GUI environment; not a verification of isolation')
p.add_argument('--prefix', default=datetime.datetime.now().strftime('verified-%Y%m%d-%H%M%S'))
p.add_argument('--rounds', type=int, default=3)
p.add_argument('--states', default='background,occluded,hidden')
a = p.parse_args()
if not 1 <= a.rounds <= 10: p.error('--rounds must be 1..10')
if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,79}', a.prefix): p.error('prefix must be a safe component of at most 80 characters')
states = a.states.split(',')
if len(states) != len(set(states)) or any(s not in ('background', 'occluded', 'hidden') for s in states): p.error('states must be unique known window states')
source = pathlib.Path(__file__).resolve().parent
repo = source.parents[1]
out = repo / '.build/mcc-safarier-probe'
flags = {'formalAcceptance': False, 'shippingAdmission': False}

# Check the whole existing parent chain before creating anything or running commands.
parents = [repo / '.build', out, out / 'runs']
for parent in parents:
    if parent.is_symlink() or (parent.exists() and not parent.is_dir()):
        p.error(f'unsafe output parent: {parent}')

if a.preflight:
    target = out / a.prefix
    try:
        for parent in parents[:2]: parent.mkdir(mode=0o700, exist_ok=True)
        target.mkdir(mode=0o700, exist_ok=False)
    except FileExistsError:
        p.error('preflight output already exists')
    # SwiftPM's scratch and caches are private and never use a replacement manifest.
    with tempfile.TemporaryDirectory(prefix='preflight-', dir=target) as private:
        private = pathlib.Path(private)
        home = private / 'home'; home.mkdir()
        scratch = private / 'scratch'; cache = private / 'cache'
        source_file = private / 'xctest.swift'; source_file.write_text('import XCTest\n')
        env = os.environ.copy()
        override = 'SWIFT_EXEC_MANIFEST' in env
        env.pop('SWIFT_EXEC_MANIFEST', None)
        env.update(HOME=str(home), CLANG_MODULE_CACHE_PATH=str(private/'clang-cache'), SWIFT_MODULECACHE_PATH=str(private/'swift-cache'), SWIFTPM_MODULECACHE_OVERRIDE=str(private/'swiftpm-module-cache'))
        commands = [
            ('developerDir', ['xcode-select', '-p']),
            ('swiftCompiler', ['xcrun', '--find', 'swiftc']),
            ('sdkPath', ['xcrun', '--show-sdk-path']),
            ('swiftVersion', ['xcrun', 'swift', '--version']),
            ('defaultManifest', ['xcrun', 'swift', 'package', '--package-path', str(repo), '--scratch-path', str(scratch), '--cache-path', str(cache), '--manifest-cache', 'none', '--disable-dependency-cache', 'dump-package']),
            ('macosPlatform', ['xcrun', '--sdk', 'macosx', '--show-sdk-platform-path']),
            ('xctestTypecheck', ['xcrun', '--sdk', 'macosx', 'swiftc', '-typecheck', '-module-cache-path', str(private/'xctest-module-cache'), str(source_file)]),
        ]
        results = {}
        for name, cmd in commands:
            if name == 'xctestTypecheck':
                platform_result = results['macosPlatform']
                output = platform_result['stdout']
                lines = output.splitlines()
                error = None
                if platform_result['exitCode'] != 0 or platform_result['timedOut']:
                    error = 'macOS platform lookup failed or timed out'
                elif len(lines) != 1 or not lines[0] or output not in (lines[0], lines[0] + '\n'):
                    error = 'macOS platform lookup must return one nonempty path line'
                else:
                    platform = pathlib.Path(lines[0])
                    if not platform.is_absolute() or platform.name != 'MacOSX.platform' or '..' in platform.parts or '\x00' in lines[0]:
                        error = 'macOS platform lookup returned an invalid absolute MacOSX.platform path'
                    else:
                        frameworks = platform/'Developer/Library/Frameworks'
                        modules = platform/'Developer/usr/lib'
                        if not platform.is_dir() or not frameworks.is_dir() or not modules.is_dir():
                            error = 'macOS platform or required Frameworks/module directory does not exist'
                if error:
                    results[name] = {'command': None, 'exitCode': None, 'stdout': '', 'stderr': error, 'timedOut': False, 'durationSeconds': 0, 'skipped': True}
                    continue
                cmd = cmd[:-1] + ['-F', str(frameworks), '-I', str(modules), cmd[-1]]
            start = time.monotonic()
            try:
                r = subprocess.run(cmd, cwd=repo, env=env, capture_output=True, text=True, errors='replace', timeout=30)
                results[name] = {'exitCode': r.returncode, 'stdout': r.stdout, 'stderr': r.stderr, 'timedOut': False}
            except subprocess.TimeoutExpired as exc:
                def text(value): return value.decode(errors='replace') if isinstance(value, bytes) else (value or '')
                results[name] = {'exitCode': None, 'stdout': text(exc.stdout), 'stderr': text(exc.stderr), 'timedOut': True}
            except OSError as exc:
                results[name] = {'exitCode': None, 'stdout': '', 'stderr': str(exc), 'timedOut': False}
            results[name]['command'] = cmd
            results[name]['durationSeconds'] = round(time.monotonic()-start, 6)
        ok = all(r['exitCode'] == 0 and not r['timedOut'] for r in results.values()) and not override
        summary = {**flags, 'GUIExecuted': False, 'fullSwiftTestRun': False, 'overrideDetected': override,
                   'probeManifestOverrideCleared': True, 'sandboxedHome': True,
                   'temporaryPathsNote': 'Private scratch, cache, home and XCTest source paths are deleted after preflight.',
                   'defaultManifestStatus': 'passed' if results['defaultManifest']['exitCode'] == 0 and not override else 'blocked',
                   'xctestStatus': 'passed' if results['xctestTypecheck']['exitCode'] == 0 else 'blocked',
                   'g0Status': 'unverified' if ok else 'blocked', 'commands': results}
        path = target / 'summary.json'; path.write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    print(json.dumps(summary, ensure_ascii=False)); sys.exit(0 if ok else 1)

labels = [(state, f'{a.prefix}-{state}-{i}') for state in states for i in range(1, a.rounds+1)]
path = out / f'{a.prefix}-matrix.json'
if path.exists() or path.is_symlink() or any((out/'runs'/label).exists() or (out/'runs'/label).is_symlink() for _, label in labels):
    p.error('matrix output already exists')
for parent in parents: parent.mkdir(mode=0o700, exist_ok=True)
try:
    reservation = path.open('x')
except FileExistsError:
    p.error('matrix output already exists')
rows = []
summary = {**flags, 'diagnosticOnly': True, 'operatorConfirmedIsolation': True, 'isolationVerified': False,
           'warning': 'Legacy diagnostic fixture uses LaunchServices and legacy PID cleanup; isolation is not verified. Not formal G1/G3 or G2/G5 acceptance and not a Safarier recipient.', 'runs': rows, 'allPassed': False}
try:
    for step in (repo/'scripts/test-native-background-input.sh', source/'build-native.sh', source/'build-probe.sh'):
        try:
            r = subprocess.run([str(step)])
        except subprocess.CalledProcessError as exc:
            summary['error'] = f'{step.name} failed: {exc.returncode}'
            summary['failedCommand'] = [str(step)]
            break
        if r.returncode:
            summary['error'] = f'{step.name} failed: {r.returncode}'
            summary['failedCommand'] = [str(step)]
            break
    else:
        for state, label in labels:
            r = subprocess.run([sys.executable, str(source/'run.py'), '--isolated-ui', '--mode', 'fixed', '--visibility', state, '--label', label])
            report = out/'runs'/label/'report.json'
            d = json.loads(report.read_text()) if report.exists() else {}
            cases = d.get('cases', [])
            rows.append({'label': label, 'state': state, 'exitCode': r.returncode, 'allPassed': d.get('allPassed', False), 'checks': len(cases), 'failed': [x['name'] for x in cases if not x['passed']], 'error': d.get('error', '' if report.exists() else 'fixture did not produce a report')})
        summary['allPassed'] = bool(rows) and all(x['allPassed'] and x['exitCode'] == 0 for x in rows)
except OSError as exc:
    summary['error'] = str(exc)
finally:
    with reservation: json.dump(summary, reservation, indent=2, ensure_ascii=False)
print('MATRIX', path); print(json.dumps(summary, indent=2, ensure_ascii=False))
sys.exit(0 if summary['allPassed'] else 1)
