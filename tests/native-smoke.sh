#!/bin/bash
# Given 不依赖授权且不操作 Chrome，When 收到 JSONL，Then 每行都有结构化响应且及时退出。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo '原生 smoke 仅支持 macOS' >&2
  exit 1
fi
scratch="$(mktemp -d /tmp/copis-chrome-native-smoke.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
helper="${1:-$scratch/copis-chrome-helper}"
host="$(rustc -vV 2>/dev/null | sed -n 's/^host: //p' || true)"
case "$host" in
  aarch64-apple-darwin) arch=arm64 ;;
  x86_64-apple-darwin) arch=x86_64 ;;
  *) arch="$(uname -m)" ;;
esac
case "$arch" in
  arm64|x86_64) ;;
  *) echo '不支持当前 macOS 架构' >&2; exit 1 ;;
esac
if [[ $# == 0 ]]; then
  shopt -s nullglob
  sources=("$root"/swift/*.swift)
  if [[ ${#sources[@]} == 0 ]]; then
    echo 'FAIL: Swift helper 尚未实现，JSONL smoke 无法取得响应' >&2
    exit 1
  fi
  swiftc -O -target "${arch}-apple-macosx14.0" "${sources[@]}" -o "$helper"
fi
# 独立 main.swift 测试入口，只链接 helper 的库文件，绝不启动应用/管道入口。
library_sources=()
for source in "$root"/swift/*.swift; do
  [[ "$(basename "$source")" == main.swift ]] || library_sources+=("$source")
done
swiftc -O -target "${arch}-apple-macosx14.0" "${library_sources[@]}" \
  "$root/tests/cancellation/main.swift" -o "$scratch/cancellation-tests"
swiftc -O -target "${arch}-apple-macosx14.0" "${library_sources[@]}" \
  "$root/tests/focus-validation/main.swift" -o "$scratch/focus-validation-tests"
swiftc -O -target "${arch}-apple-macosx14.0" "${library_sources[@]}" \
  "$root/tests/file-dialog/main.swift" -o "$scratch/file-dialog-tests"
swiftc -O -target "${arch}-apple-macosx14.0" "${library_sources[@]}" \
  "$root/tests/execution-control/main.swift" -o "$scratch/execution-control-tests"
swiftc -O -target "${arch}-apple-macosx14.0" "${library_sources[@]}" \
  "$root/tests/text-recognition/main.swift" -o "$scratch/text-recognition-tests"
swiftc -O -target "${arch}-apple-macosx14.0" "${library_sources[@]}" \
  "$root/tests/application-scope/main.swift" -o "$scratch/application-scope-tests"
swiftc -O -target "${arch}-apple-macosx14.0" "${library_sources[@]}" \
  "$root/tests/cursor-motion/main.swift" -o "$scratch/cursor-motion-tests"
"$scratch/cursor-motion-tests"
"$scratch/application-scope-tests"
"$scratch/text-recognition-tests"
"$scratch/execution-control-tests"
"$scratch/file-dialog-tests"
"$scratch/focus-validation-tests"
swiftc -O -target "${arch}-apple-macosx14.0" "${library_sources[@]}" \
  "$root/tests/toast-layout/main.swift" -o "$scratch/toast-layout-tests"
"$scratch/toast-layout-tests"
swiftc -O -target "${arch}-apple-macosx14.0" "${library_sources[@]}" \
  "$root/tests/capture-fallback/main.swift" -o "$scratch/capture-fallback-tests"
"$scratch/capture-fallback-tests"
swiftc -O -target "${arch}-apple-macosx14.0" "${library_sources[@]}" \
  "$root/tests/pointer-target/main.swift" -o "$scratch/pointer-target-tests"
"$scratch/pointer-target-tests"
/usr/bin/python3 - "$helper" "$scratch/cancellation-tests" <<'PY'
import json
import os
import selectors
import subprocess
import sys

# fake effect 测试也设置进程级上限，锁释放回归不能让 smoke 死等。
subprocess.run([sys.argv[2]], check=True, timeout=12)
helper = sys.argv[1]
checks = []

def invalid(label, payload, code="INVALID_ARGUMENT"):
    checks.append((label, payload, code))

# Given 请求无效，Then 参数错误优先于系统权限和任何桌面副作用。
invalid("未知动作", {"action": "not-an-action"}, "UNKNOWN_ACTION")
invalid("未知字段", {"action": "cancel", "unexpected": True})
invalid("权限布尔类型", {"action": "permissions", "request": 1})
invalid("权限未知字段", {"action": "permissions", "screenRecording": True})
invalid("窗口枚举未知字段", {"action": "windows", "pid": 1})
invalid("窗口零编号", {"action": "window", "windowId": 0, "pid": 1})
invalid("窗口负编号", {"action": "window", "windowId": -1, "pid": 1})
invalid("窗口溢出", {"action": "window", "windowId": 2**32, "pid": 1})
invalid("窗口非整数", {"action": "window", "windowId": 1.5, "pid": 1})
invalid("窗口布尔值", {"action": "window", "windowId": True, "pid": 1})
invalid("进程溢出", {"action": "window", "windowId": 1, "pid": 2**31})
invalid("进程负值", {"action": "window", "windowId": 1, "pid": -1})
invalid("进程字符串", {"action": "window", "windowId": 1, "pid": "1"})
base = {"windowId": 1, "pid": 1}
bounds = {"x": 0, "y": 0, "width": 800, "height": 600}
input_base = dict(base, expectedBounds=bounds)
for action, args in [
    ("click", {"screenX": 10, "screenY": 20, "clickCount": 1}),
    ("scroll", {"screenX": 10, "screenY": 20, "deltaY": 1}),
    ("type", {"text": "禁止回显的测试原文"}),
    ("press", {"key": "Enter"}),
]:
    invalid(action + "缺少几何", dict(base, action=action, **args))
    invalid(action + "未知字段", dict(input_base, action=action, extra=True, **args))
    for value in [None, {}, dict(bounds, width=0), dict(bounds, height=-1),
                  dict(bounds, x=True), dict(bounds, extra=1), dict(bounds, x=1e100)]:
        invalid(action + "错误几何", dict(base, action=action, expectedBounds=value, **args))
for value in [0, 3, -1, True, 1.2, "1"]:
    invalid("点击次数", dict(input_base, action="click", screenX=10, screenY=20, clickCount=value))
for field, value in [("screenX", True), ("screenY", "0"), ("screenX", 800),
                     ("screenY", -1), ("screenX", 1e100)]:
    args = dict(input_base, action="click", screenX=10, screenY=20, clickCount=1)
    args[field] = value
    invalid("错误点击坐标", args)
for value in [0, -1201, 1201, True, 0.5, "1"]:
    invalid("滚动范围", dict(input_base, action="scroll", screenX=10, screenY=20, deltaY=value))
for text in ["", "x" * 4097, "😀" * 4097, "禁止回显\n", "\x00", "\x7f", "\x85", 7]:
    invalid("非法输入文本", dict(input_base, action="type", text=text))
for key in ["", "Cmd+Q", "enter", "禁止回显的按键", 13]:
    invalid("非法按键", dict(input_base, action="press", key=key))
for path in ["", "relative.jpg", "/tmp/../invalid.jpg", "/tmp/bad\x00.jpg", "/tmp/"]:
    invalid("非法截图路径", dict(base, action="observe", imagePath=path, maxEdge=1600))
for path in ["", "relative.txt", "file:///tmp/a", "/tmp/../a", "/tmp/./a", "/tmp/a\n", "/tmp/", "/" + "字" * 1400]:
    invalid("非法文件路径", dict(base, action="select-file", path=path))
invalid("文件不存在先于任何桌面副作用", dict(base, action="select-file", path="/copis-nonexistent-file-8e2566"), "FILE_NOT_READABLE")
for edge in [0, 1601, True, "1600", 1599]:
    invalid("截图最长边", dict(base, action="observe", imagePath="/tmp/no-capture.jpg", maxEdge=edge))
invalid("缺少动作", {}, "INVALID_REQUEST")
invalid("错误动作类型", {"action": 1}, "INVALID_REQUEST")

lines = []
expected = {}
for index, (label, payload, code) in enumerate(checks):
    request_id = str(index)
    payload = dict(payload, id=request_id)
    lines.append(json.dumps(payload, ensure_ascii=False))
    expected[request_id] = (label, {code})
# 合法边界使用 launchd 的 PID 1，绝不可能激活 Chrome；验证不会错误拒绝白名单/Unicode。
safe_input = dict(input_base, windowId=2**32 - 1)
safe_failures = {"CANCELLED", "WINDOW_UNAVAILABLE", "ACCESSIBILITY_PERMISSION_REQUIRED"}
valid_boundaries = [
    dict(safe_input, action="type", text="👩‍💻"),
    dict(safe_input, action="type", text="x" * 4096),
    dict(safe_input, action="type", text="😀" * 4096),
    dict(safe_input, action="type", text="禁止回显的合法文本"),
    dict(safe_input, action="scroll", screenX=0, screenY=0, deltaY=-1200),
    dict(safe_input, action="scroll", screenX=799.5, screenY=599.5, deltaY=1200),
    dict(safe_input, action="click", screenX=0, screenY=0, clickCount=2),
]
keys = ["Enter", "Tab", "Shift+Tab", "Escape", "Backspace", "Delete", "ArrowUp", "ArrowDown",
        "ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown", "Cmd+L", "Cmd+A", "Cmd+R",
        "Cmd+T", "Cmd+W", "Alt+ArrowLeft", "Alt+ArrowRight"]
valid_boundaries += [dict(safe_input, action="press", key=key) for key in keys]
for index, payload in enumerate(valid_boundaries):
    rid = "valid-" + str(index)
    lines.append(json.dumps(dict(payload, id=rid), ensure_ascii=False))
    expected[rid] = ("合法输入边界，不应判为参数错误", safe_failures)
lines += [json.dumps({"id": "permissions", "action": "permissions", "request": False}),
          json.dumps({"id": "cancel", "action": "cancel"})]
# 不关闭 stdin 也必须立即得到 JSON；响应不能依赖 EOF 才刷新。
p = subprocess.Popen([helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
try:
    p.stdin.write(b'{"id":"live","action":"cancel"}\n')
    ready = selectors.DefaultSelector()
    ready.register(p.stdout, selectors.EVENT_READ)
    assert ready.select(3), "stdout 没有及时输出，或主 RunLoop 被阻塞"
    live = json.loads(p.stdout.readline())
    assert live == {"id": "live", "ok": True, "data": {"cancelled": True}}, live
    # PID 1 永远不是 Chrome：校验有效输入的权限错误码，不会激活或发送事件。
    p.stdin.write((json.dumps(dict(safe_input, id="permission-code", action="press", key="Enter")) + "\n").encode())
    assert ready.select(3), "有效输入未在有限时间内响应"
    safe = json.loads(p.stdout.readline())
    assert safe["ok"] is False and safe["error"]["code"] in {"WINDOW_UNAVAILABLE", "ACCESSIBILITY_PERMISSION_REQUIRED"}, safe
    ready.close()
    stdout, stderr = p.communicate(("\n".join(lines) + "\n").encode(), timeout=15)
    assert p.returncode == 0, (p.returncode, stderr)
    replies = [json.loads(line) for line in stdout.splitlines()]
    assert len(replies) == len(lines), (len(replies), len(lines))
    seen = set()
    for reply in replies:
        rid = reply["id"]
        assert rid not in seen, ("重复响应", reply)
        seen.add(rid)
        if rid in expected:
            label, codes = expected[rid]
            assert set(reply) == {"id", "ok", "error"}, (label, reply)
            assert reply["ok"] is False and reply["error"]["code"] in codes, (label, reply)
            assert set(reply["error"]) == {"code", "message"} and reply["error"]["message"], reply
        elif rid == "permissions":
            assert set(reply) == {"id", "ok", "data"} and reply["ok"] is True, reply
            assert set(reply["data"]) == {"screenRecording", "accessibility"}, reply
            assert all(type(v) is bool for v in reply["data"].values()), reply
        elif rid == "cancel":
            assert reply == {"id": rid, "ok": True, "data": {"cancelled": True}}, reply
        else:
            raise AssertionError(("意外响应", reply))
    assert not stderr, ("协议路径不应记录输入或错误详情", stderr)
    assert "禁止回显" not in stdout.decode(), "输入文本被回显"
finally:
    if p.poll() is None:
        p.kill()
        p.wait()

# Given 畸形行和超长行，Then 每行一错误，仍可处理下一行，EOF 不死等。
malformed = [b"not-json", b"[]", b"null", b"", b"{", b"\xff", b"x" * (65536 + 1),
             b'{"id":"","action":"cancel"}', b'{"id":3,"action":"cancel"}']
for raw in malformed:
    probe = subprocess.run([helper], input=raw + b'\n{"id":"after","action":"cancel"}\n',
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
    reply = [json.loads(line) for line in probe.stdout.splitlines()]
    assert probe.returncode == 0 and len(reply) == 2, (raw[:20], probe.stdout, probe.stderr)
    assert reply[0]["id"] == "" and reply[0]["ok"] is False, reply
    assert reply[0]["error"]["code"] in {"INVALID_REQUEST", "REQUEST_TOO_LARGE"}, reply
    assert reply[1] == {"id": "after", "ok": True, "data": {"cancelled": True}}, reply
# 最后一行没有换行也必须响应。
probe = subprocess.run([helper], input=b'{"id":"tail","action":"cancel"}',
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
assert json.loads(probe.stdout) == {"id": "tail", "ok": True, "data": {"cancelled": True}}
assert probe.returncode == 0
# 无效命令行参数必须结构化报错，不启动桌面动作。
probe = subprocess.run([helper, "--unknown"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
reply = json.loads(probe.stdout)
assert probe.returncode == 1 and reply["ok"] is False and reply["error"]["code"] == "INVALID_ARGUMENT", reply
# Given daemon 已断开 stdout，Then helper 不抛异常、不泄露请求、不死等。
read_fd, write_fd = os.pipe()
os.close(read_fd)
probe = subprocess.Popen([helper], stdin=subprocess.PIPE, stdout=write_fd, stderr=subprocess.PIPE)
os.close(write_fd)
try:
    _, stderr = probe.communicate(b'{"id":"closed-reader","action":"cancel"}\n', timeout=5)
    assert probe.returncode == 0 and not stderr, (probe.returncode, stderr)
finally:
    if probe.poll() is None:
        probe.kill()
        probe.wait()
print(f"PASS: {len(lines) + len(malformed) * 2 + 5} 项无副作用 JSONL smoke 检查；未申请权限、未激活/输入/截图")
PY
