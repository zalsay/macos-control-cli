#!/bin/bash
# 验证独立分发包与双语文档，不启动 daemon、Chrome 或系统输入。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root" <<'PY'
import hashlib
import json
from pathlib import Path
import platform
import re
import subprocess
import sys
import tarfile

root = Path(sys.argv[1])
version = re.search(r'^version = "([^"]+)"', (root / 'Cargo.toml').read_text(), re.M).group(1)
arch = {'arm64': 'arm64', 'x86_64': 'x64'}[platform.machine()]
name = f'copis-chrome-{version}-darwin-{arch}'
package = root / 'dist' / name
archive = root / 'dist' / f'{name}.tar.gz'
required = ['copis-chrome', 'copis-chrome-helper', 'module.json', 'LICENSE', 'USAGE.md',
            'README.md', 'README.zh-CN.md', 'assets/copis-logo.png', 'docs/AGENT-INTEGRATION.md',
            'source/Cargo.toml', 'source/Cargo.lock', 'source/build.sh', 'source/README.md',
            'source/README.zh-CN.md', 'source/src/main.rs', 'source/swift/main.swift']
for relative in required:
    assert (package / relative).is_file(), f'缺少独立产物：{relative}'
metadata = json.loads((package / 'module.json').read_text())
assert metadata['version'] == version and metadata['arch'] == arch
assert metadata['protocolVersion'] == 1 and metadata['entrypoint'] == 'copis-chrome'
expected_hash = archive.with_name(archive.name + '.sha256').read_text().split()[0]
assert hashlib.sha256(archive.read_bytes()).hexdigest() == expected_hash, '归档 SHA256 不匹配'
with tarfile.open(archive) as tar:
    names = {member.name.rstrip('/') for member in tar.getmembers()}
    for relative in required:
        assert f'{name}/{relative}' in names, f'归档缺少 {relative}'
    assert not any(any(part in ['.git', 'target', '.env', 'runtime', 'frames'] for part in Path(n).parts) for n in names), '归档夹带运行数据或非源码目录'
for folder in ['src', 'swift', 'tests', 'assets', 'docs']:
    for source in (root / folder).rglob('*'):
        if source.is_file():
            assert source.read_bytes() == (package / 'source' / source.relative_to(root)).read_bytes(), f'包内源码不一致：{source}'
for base in [root, package, package / 'source']:
    for doc in [base / 'README.md', base / 'README.zh-CN.md', base / 'USAGE.md', *(base / 'docs').glob('*.md')]:
        for ref in re.findall(r'!?\[[^\]]*\]\(([^)]+)\)', doc.read_text()):
            path = ref.split('#')[0]
            if path and '://' not in path and not path.startswith('mailto:'):
                assert (doc.parent / path).exists(), f'文档链接失效：{doc.name} -> {path}'
reply = json.loads(subprocess.check_output([str(package / 'copis-chrome'), '--version'], text=True))
assert reply['ok'] and reply['version'] == version
print('PASS: 独立双二进制包、双语 README、源码完整性、文档链接、SHA256 与无运行数据；未启动桌面自动化')
PY
