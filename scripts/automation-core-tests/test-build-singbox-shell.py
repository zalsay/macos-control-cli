import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

# Each stub validates every path it writes against the private mirror.
STUB = r'''#!{python}
import json, os, pathlib, sys
root = pathlib.Path(os.environ['MIRROR_ROOT']).resolve()
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
def private(value):
    p = pathlib.Path(value).resolve()
    if not p.is_relative_to(root):
        raise SystemExit('outside mirror: ' + str(p))
    return p
with (root / 'calls.jsonl').open('a') as f:
    f.write(json.dumps(dict(name=name, args=args, env={{k: os.environ.get(k) for k in ('CGO_ENABLED', 'GOOS', 'GOARCH')}})) + '\n')
if name == 'git':
    if args[:1] == ['clone']:
        raise SystemExit('clone forbidden')
    assert args == ['-C', str(root / 'out/sing-box-src/1.14.4'), 'rev-parse', 'HEAD']
    print('stub-commit')
elif name == 'go':
    if args == ['version']:
        print('go version stub-go darwin/arm64')
    else:
        assert args[0] == 'build'
        out = private(args[args.index('-o') + 1])
        out.write_text('stub binary ' + os.environ['GOARCH'])
elif name == 'lipo':
    if args[0] == '-create':
        out = private(args[args.index('-output') + 1])
        for item in args[3:]:
            assert private(item).is_file()
        out.write_text('stub universal')
    else:
        assert args[0] == '-archs' and private(args[1]).is_file()
        print('arm64 x86_64')
elif name == 'curl':
    assert args[:2] == ['-fsSL', 'https://www.gnu.org/licenses/gpl-3.0.txt'] and args[2] == '-o'
    private(args[3]).write_text('GNU GENERAL PUBLIC LICENSE\nstub license\n')
elif name == 'sha256sum':
    assert private(args[0]).is_file()
    print('a' * 64 + '  ' + args[0])
else:
    raise SystemExit('unexpected stub')
'''


class BuildSingboxShell(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='singbox-shell-mirror-')
        self.root = Path(self.tmp.name).resolve()
        self.addCleanup(self.tmp.cleanup)
        (self.root / 'scripts').mkdir()
        script = (ROOT / 'scripts/build-singbox.sh').read_text()
        # Diagnostic only: expose the next original Bash 3 failure after arch.
        if os.environ.get('MIRROR_FIX_ARCH_ONLY') == '1':
            script = script.replace('$arch（', '${arch}（')
        (self.root / 'scripts/build-singbox.sh').write_text(script)
        src = self.root / 'out/sing-box-src/1.14.4'
        (src / '.git').mkdir(parents=True)
        (src / 'LICENSE').write_text('upstream copyright stub\n')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name in ('git', 'go', 'lipo', 'curl', 'sha256sum'):
            path = self.bin / name
            path.write_text(STUB.format(python=sys.executable))
            path.chmod(0o755)
        # No fallback PATH: no real git, Go, curl, lipo, or hash tool can run.
        for name in ('dirname', 'rm', 'mkdir', 'cp', 'grep', 'cut', 'ls'):
            (self.bin / name).symlink_to(shutil.which(name))
        self.env = {'PATH': str(self.bin), 'MIRROR_ROOT': str(self.root),
                    'HOME': str(self.root), 'LC_ALL': 'en_US.UTF-8'}

    def run_script(self, **env):
        return subprocess.run(['/bin/bash', str(self.root / 'scripts/build-singbox.sh')],
                              env=dict(self.env, **env), capture_output=True, text=True,
                              errors='replace', timeout=10)

    def calls(self, name):
        return [c for c in map(json.loads, (self.root / 'calls.jsonl').read_text().splitlines())
                if c['name'] == name]

    def test_default_two_architectures_and_source(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        out = self.root / 'out/sing-box'
        builds = [c for c in self.calls('go') if c['args'][0] == 'build']
        self.assertEqual(len(builds), 2)
        for call, arch in zip(builds, ('arm64', 'amd64')):
            self.assertEqual(call['env'], {'CGO_ENABLED': '0', 'GOOS': 'darwin', 'GOARCH': arch})
            self.assertEqual(call['args'], ['build', '-trimpath', '-tags', 'with_utls', '-ldflags',
                             '-s -w -buildid= -X github.com/sagernet/sing-box/constant.Version=1.14.4',
                             '-o', str(out / ('sing-box-' + arch)), './cmd/sing-box'])
            self.assertIn('darwin/' + arch + '（tags: with_utls）', result.stdout)
        self.assertEqual(len(self.calls('lipo')), 2)
        self.assertEqual((out / 'sing-box').read_text(), 'stub universal')
        self.assertEqual((out / 'LICENSE').read_text(), 'upstream copyright stub\n')
        self.assertEqual((out / 'COPYING').read_text(), 'GNU GENERAL PUBLIC LICENSE\nstub license\n')
        source = (out / 'SOURCE').read_text()
        for text in ('sing-box 1.14.4，GPL-3.0-or-later',
                     'https://github.com/SagerNet/sing-box/tree/v1.14.4（commit stub-commit）',
                     'go version stub-go darwin/arm64', 'build tags：with_utls',
                     'darwin/arm64：CGO_ENABLED=0 GOOS=darwin GOARCH=arm64',
                     'darwin/amd64：CGO_ENABLED=0 GOOS=darwin GOARCH=amd64',
                     'LICENSE', 'COPYING'):
            self.assertIn(text, source)
        self.assertEqual(source.count('sha256 ' + 'a' * 64), 2)
        self.assertEqual(len(self.calls('curl')), 1)
        self.assertEqual([c['args'][0] for c in self.calls('git')], ['-C'])

    def test_single_arch_empty_tags_without_lipo(self):
        (self.bin / 'lipo').unlink()
        result = self.run_script(SINGBOX_ARCHS='arm64', SINGBOX_TAGS='')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        out = self.root / 'out/sing-box'
        builds = [c for c in self.calls('go') if c['args'][0] == 'build']
        self.assertEqual(len(builds), 1)
        self.assertEqual(builds[0]['args'][builds[0]['args'].index('-tags') + 1], '')
        self.assertFalse((out / 'sing-box').exists())
        self.assertIn('darwin/arm64（tags: 无）', result.stdout)
        source = (out / 'SOURCE').read_text()
        self.assertIn('build tags：无', source)
        self.assertIn('darwin/arm64：', source)
        self.assertNotIn('darwin/amd64：', source)


if __name__ == '__main__':
    unittest.main(verbosity=2)
