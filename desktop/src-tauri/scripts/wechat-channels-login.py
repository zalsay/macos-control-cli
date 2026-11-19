#!/usr/bin/env python3
"""Guarded MCC orchestration for the WeChat Channels login flow.

No action is run unless --execute is explicitly supplied. This module is
intentionally limited to MCC CLI calls; it never talks to Chrome/WeChat/BLE
directly and never stores account data or credentials.
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable, Sequence
from urllib.parse import urlsplit

CHROME = "com.google.Chrome"
WECHAT_BUNDLES = ("com.tencent.xinWeChat", "com.tencent.WeChat")
LOGIN_LABEL = "微信快捷登录"
ALLOW_LABEL = "允许"
LEGACY_ALLOW_LABEL = "允许登录"
SUCCESS_LABELS = ("作品管理", "内容管理", "视频管理", "视频数据")
MIN_CONFIDENCE = 0.85
MAX_POLLS = 30


class FlowError(Exception):
    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


def subprocess_runner(argv: Sequence[str], timeout: float) -> dict:
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as exc:
        raise FlowError("MCC_TIMEOUT") from exc
    except OSError as exc:
        raise FlowError("MCC_UNAVAILABLE") from exc
    try:
        value = json.loads(result.stdout)
    except (ValueError, TypeError) as exc:
        raise FlowError("MCC_OUTPUT_INVALID") from exc
    if not isinstance(value, dict):
        raise FlowError("MCC_OUTPUT_INVALID")
    if result.returncode != 0 or value.get("ok") is False:
        code = value.get("error", {}).get("code", "MCC_REQUEST_FAILED")
        raise FlowError(str(code)[:80])
    return value


class MCC:
    def __init__(self, args: argparse.Namespace, runner: Callable = subprocess_runner,
                 clock: Callable[[], float] = time.monotonic):
        self.runner = runner
        self.timeout = args.command_timeout
        self.clock = clock
        self.deadline_at: float | None = None
        self.prefix = [args.mcc]
        if args.remote:
            self.prefix += ["--remote", args.remote]
            if args.ca_cert:
                self.prefix += ["--ca-cert", args.ca_cert]
            self.prefix += ["--token-file", args.token_file]
            if args.remote_state_dir:
                self.prefix += ["--remote-state-dir", args.remote_state_dir]

    def call(self, action: str, *options: str) -> dict:
        timeout = self.timeout
        if self.deadline_at is not None and action != "disconnect":
            remaining = self.deadline_at - self.clock()
            if remaining <= 0:
                raise FlowError("FLOW_DEADLINE_EXCEEDED")
            timeout = min(timeout, remaining)
        return self.runner([*self.prefix, action, *options], timeout)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--execute", action="store_true", help="执行桌面流程")
    mode.add_argument("--plan", action="store_true", help="只输出计划（默认）")
    p.add_argument("--mcc", default=shutil.which("mcc") or "mcc",
                   help="Desktop-scope MCC CLI，可为本地 mcc/desktop-control 或匹配的远端客户端")
    p.add_argument("--remote", help="desktop-scope Host 的 wss://.../mcc/v1 地址")
    p.add_argument("--ca-cert", help="远端 Host CA 证书路径")
    p.add_argument("--token-file", help="远端 Host token 文件路径；不接受 token 明文")
    p.add_argument("--remote-state-dir", help="远端客户端私有状态目录")
    p.add_argument("--chrome-window", type=int, help="明确指定已有视频号助手 Chrome windowId")
    p.add_argument("--wechat-window", type=int, help="明确指定当前微信授权 windowId")
    p.add_argument("--login-label", action="append", help="明确添加登录按钮同义标签，可重复")
    p.add_argument("--allow-label", action="append",
                   help="添加精确授权按钮标签；默认匹配“允许”，兼容“允许登录”，可重复")
    p.add_argument("--success-label", action="append", help="明确添加登录后页面标记，可重复")
    p.add_argument("--poll-limit", type=int, default=12, help="每个页面等待最多观察次数 (1–30)")
    p.add_argument("--poll-interval", type=float, default=1.0, help="只读观察间隔秒数，默认 1.0 (0–5)")
    p.add_argument("--step-delay", type=float, default=1.5, help="关键步骤间等待秒数，默认 1.5 (1–2)")
    p.add_argument("--command-timeout", type=float, default=25.0, help="单次 MCC 命令超时秒数")
    p.add_argument("--deadline-seconds", type=float, default=120.0, help="整个流程总时限秒数 (5–600)")
    a = p.parse_args(argv)
    if not 1 <= a.poll_limit <= MAX_POLLS or not 0 <= a.poll_interval <= 5:
        p.error("poll-limit 必须为 1–30，poll-interval 必须为 0–5")
    if not 1 <= a.step_delay <= 2:
        p.error("step-delay 必须为 1–2 秒")
    if not 1 <= a.command_timeout <= 120:
        p.error("command-timeout 必须为 1–120 秒")
    if not 5 <= a.deadline_seconds <= 600:
        p.error("deadline-seconds 必须为 5–600 秒")
    if a.remote:
        u = urlsplit(a.remote)
        if (u.scheme != "wss" or not u.hostname or u.username or u.password or u.query or u.fragment
                or u.path not in ("", "/", "/mcc/v1")):
            p.error("remote 必须是无凭据的 wss Host 地址")
        if not a.token_file or not Path(a.token_file).is_absolute():
            p.error("远端模式需要绝对路径 --token-file；不接受 token 明文")
    elif a.ca_cert or a.token_file or a.remote_state_dir:
        p.error("CA/token/state 参数仅能与 --remote 一起使用")
    if a.ca_cert and not Path(a.ca_cert).is_absolute():
        p.error("ca-cert 必须为绝对路径")
    if a.remote_state_dir and not Path(a.remote_state_dir).is_absolute():
        p.error("remote-state-dir 必须为绝对路径")
    return a


class Flow:
    def __init__(self, args: argparse.Namespace, runner: Callable = subprocess_runner,
                 sleep: Callable[[float], None] | None = None,
                 clock: Callable[[], float] = time.monotonic):
        self.args, self.sleep, self.clock = args, (time.sleep if sleep is None else sleep), clock
        self.deadline_at = clock() + args.deadline_seconds
        self.mcc = MCC(args, runner, clock)
        self.mcc.deadline_at = self.deadline_at
        self.owned: set[str] = set()
        self.disconnect_attempted: set[str] = set()
        self.trace: list[dict] = []
        self.login_labels = tuple(dict.fromkeys([LOGIN_LABEL, *(args.login_label or [])]))
        self.allow_labels = tuple(dict.fromkeys(
            [ALLOW_LABEL, LEGACY_ALLOW_LABEL, *(args.allow_label or [])]))
        self.success_labels = tuple(dict.fromkeys([*SUCCESS_LABELS, *(args.success_label or [])]))

    def note(self, step: str, result: str = "ok", **details: object) -> None:
        self.trace.append({"step": step, "result": result, **details})

    def wait(self) -> None:
        remaining = self.deadline_at - self.clock()
        if remaining <= 0:
            raise FlowError("FLOW_DEADLINE_EXCEEDED")
        self.sleep(min(self.args.poll_interval, remaining))
        if self.clock() >= self.deadline_at:
            raise FlowError("FLOW_DEADLINE_EXCEEDED")

    def step_delay(self, stage: str) -> None:
        requested = self.args.step_delay
        remaining = self.deadline_at - self.clock()
        if remaining <= 0:
            self.note("step_delay", "deadline", stage=stage, seconds=0)
            raise FlowError("FLOW_DEADLINE_EXCEEDED")
        seconds = min(requested, remaining)
        self.note("step_delay", "ok" if seconds == requested else "deadline",
                  stage=stage, seconds=seconds, requested_seconds=requested)
        self.sleep(seconds)
        if seconds < requested or self.clock() >= self.deadline_at:
            raise FlowError("FLOW_DEADLINE_EXCEEDED")

    def ensure_idle(self) -> None:
        status = self.mcc.call("status")
        if status.get("connected") is True:
            raise FlowError("EXISTING_CONNECTION_NOT_OWNED")

    def windows(self, bundle: str) -> list[dict]:
        data = self.mcc.call("windows", "--app", bundle)
        return [w for w in data.get("windows", []) if isinstance(w, dict)]

    def connect(self, window: dict, expected_bundle: str) -> str:
        self.ensure_idle()
        data = self.mcc.call("connect", "--window", str(window["windowId"]))
        cid = data.get("connectionId")
        if data.get("connected") is not True or not isinstance(cid, str) or not cid:
            raise FlowError("CONNECT_RECEIPT_INVALID")
        self.owned.add(cid)
        actual = data.get("window", {}).get("bundleId")
        if actual != expected_bundle:
            raise FlowError("CONNECTED_WINDOW_IDENTITY_MISMATCH")
        return cid

    def disconnect(self, cid: str) -> None:
        if cid not in self.owned or cid in self.disconnect_attempted:
            return
        self.disconnect_attempted.add(cid)  # never replay a failed cleanup request
        try:
            data = self.mcc.call("disconnect", "--connection", cid)
        except FlowError:
            self.note("owned_connection_cleanup", "unconfirmed")
            raise
        if data.get("connected") is not False:
            self.note("owned_connection_cleanup", "unconfirmed")
            raise FlowError("DISCONNECT_RECEIPT_INVALID")
        self.owned.discard(cid)

    def observe(self, cid: str) -> dict:
        frame = self.mcc.call("observe", "--connection", cid)
        if (not isinstance(frame.get("frameId"), str) or not frame["frameId"]
                or not isinstance(frame.get("width"), int) or not isinstance(frame.get("height"), int)):
            raise FlowError("OBSERVE_RECEIPT_INVALID")
        return frame

    @staticmethod
    def texts(frame: dict) -> list[str]:
        ocr = frame.get("ocr", {})
        if (ocr.get("status") != "ok" or ocr.get("truncated") is True
                or not isinstance(ocr.get("items"), list)):
            return []
        return [str(item.get("text", "")) for item in ocr["items"] if isinstance(item, dict)]

    @staticmethod
    def has_domain(frame: dict) -> bool:
        """Require an isolated exact host in the browser-chrome strip, not page text."""
        import urllib.parse
        ocr = frame.get("ocr", {})
        if ocr.get("status") != "ok" or ocr.get("truncated") is True:
            return False
        for item in ocr.get("items", []):
            if not isinstance(item, dict) or not isinstance(item.get("bbox"), dict):
                continue
            box = item["bbox"]
            try:
                y, height = int(box["y"]), int(box["height"])
                x, width = int(box["x"]), int(box["width"])
                confidence = float(item["confidence"])
            except (KeyError, TypeError, ValueError):
                continue
            if (x < 0 or width <= 0 or x + width > frame["width"] or y < 35 or height <= 0
                    or y + height > 95 or not MIN_CONFIDENCE <= confidence <= 1):
                continue
            token = str(item.get("text", "")).strip()
            if not token or any(ch.isspace() for ch in token):
                continue
            if "://" in token and not token.lower().startswith("https://"):
                continue
            try:
                parsed = urllib.parse.urlsplit(token if "://" in token else "//" + token)
            except ValueError:
                continue
            if (parsed.scheme in ("", "https") and parsed.hostname == "channels.weixin.qq.com"
                    and not parsed.username
                    and not parsed.password and parsed.netloc == "channels.weixin.qq.com"):
                return True
        return False

    @staticmethod
    def has_context(texts: Sequence[str]) -> bool:
        joined = " ".join(texts)
        return "视频号" in joined and ("助手" in joined or "微信" in joined)

    @staticmethod
    def has_wechat_authorization_context(texts: Sequence[str]) -> bool:
        """Require the specific Channels Platform request before an allow click.

        OCR may split labels across items or whitespace. Vision has also read
        the first character of "申请使用" as "甲"; accept that narrow variant
        only alongside the authorization details label.
        """
        joined = "".join("".join(str(text).split()) for text in texts)
        if "视频号创作平台" not in joined:
            return False
        if "申请使用" in joined:
            return True
        return "甲请使用" in joined and "你的昵称、头像" in joined

    def candidate(self, frame: dict, labels: Sequence[str], prior_frames: set[str]) -> dict | None:
        if frame["frameId"] in prior_frames:
            raise FlowError("STALE_FRAME")
        ocr = frame.get("ocr", {})
        if ocr.get("status") != "ok" or ocr.get("truncated") is True:
            return None
        matches = []
        for item in ocr.get("items", []):
            if not isinstance(item, dict) or item.get("text") not in labels:
                continue
            matches.append(item)
        if len(matches) > 1:
            raise FlowError("AMBIGUOUS_OCR_TARGET")
        if not matches:
            return None
        item = matches[0]
        box, center = item.get("bbox", {}), item.get("center", {})
        try:
            x, y = int(center["x"]), int(center["y"])
            bx, by = int(box["x"]), int(box["y"])
            bw, bh = int(box["width"]), int(box["height"])
            confidence = float(item["confidence"])
        except (KeyError, TypeError, ValueError):
            return None
        if (not 0 <= confidence <= 1 or confidence < MIN_CONFIDENCE or bw <= 0 or bh <= 0
                or bx < 0 or by < 0 or bx + bw > frame["width"] or by + bh > frame["height"]
                or not bx <= x < bx + bw or not by <= y < by + bh):
            return None
        return {"x": x, "y": y, "label": item["text"]}

    @staticmethod
    def valid_chrome_window(window: dict) -> bool:
        return (window.get("bundleId") == CHROME and "视频号助手" in str(window.get("title", "")))

    def choose_chrome(self) -> dict:
        windows = self.windows(CHROME)
        candidates = [w for w in windows if self.valid_chrome_window(w)]
        explicit = self.args.chrome_window
        if explicit is not None:
            candidates = [w for w in candidates if w.get("windowId") == explicit]
        if len(candidates) != 1:
            raise FlowError("CHROME_WINDOW_NOT_FOUND" if not candidates else "AMBIGUOUS_CHROME_WINDOW")
        return candidates[0]

    def verify_chrome_context(self, frame: dict, window: dict) -> bool:
        texts = self.texts(frame)
        page_title = "视频号助手" in str(window.get("title", "")) or "视频号助手" in " ".join(texts)
        return self.has_domain(frame) and page_title

    def wait_for_target(self, cid: str, window: dict, labels: Sequence[str],
                        *, chrome: bool, prior_frames: set[str] | None = None) -> tuple[dict, dict]:
        seen: set[str] = set(prior_frames or ())
        for index in range(self.args.poll_limit):
            frame = self.observe(cid)
            if frame["frameId"] in seen:
                raise FlowError("STALE_FRAME")
            seen.add(frame["frameId"])
            self.note("post_refresh_observe" if chrome else "wechat_observe", "polled",
                      poll=index + 1)
            context = (self.verify_chrome_context(frame, window) if chrome
                       else self.has_wechat_authorization_context(self.texts(frame)))
            found = self.candidate(frame, labels, set()) if context else None
            if found:
                return frame, found
            if index + 1 < self.args.poll_limit and self.args.poll_interval:
                self.wait()
        raise FlowError("TARGET_NOT_FOUND_OR_UNVERIFIED")

    def choose_wechat(self, baseline: set[tuple[str, int]]) -> dict:
        for attempt in range(self.args.poll_limit):
            current = [w for bundle in WECHAT_BUNDLES for w in self.windows(bundle)
                       if isinstance(w.get("windowId"), int)]
            if self.args.wechat_window is not None:
                selected = [w for w in current if w.get("windowId") == self.args.wechat_window]
            else:
                new = [w for w in current if (str(w.get("bundleId")), w["windowId"]) not in baseline]
                selected = new
            if len(selected) > 1:
                raise FlowError("AMBIGUOUS_WECHAT_WINDOW")
            if selected:
                if selected[0].get("bundleId") not in WECHAT_BUNDLES:
                    raise FlowError("WECHAT_WINDOW_IDENTITY_MISMATCH")
                self.note("wechat_window_poll", "found", poll=attempt + 1)
                return selected[0]
            self.note("wechat_window_poll", "waiting", poll=attempt + 1)
            if attempt + 1 < self.args.poll_limit and self.args.poll_interval:
                self.wait()
        raise FlowError("WECHAT_WINDOW_NOT_FOUND")

    def execute(self) -> dict:
        chrome_cid = wechat_cid = None
        approval_dismissed = False
        try:
            self.ensure_idle()
            chrome = self.choose_chrome()
            baseline = {(bundle, int(w["windowId"])) for bundle in WECHAT_BUNDLES
                        for w in self.windows(bundle) if isinstance(w.get("windowId"), int)}
            self.note("target_windows_selected")
            chrome_cid = self.connect(chrome, CHROME)
            self.step_delay("chrome_connected")
            initial = self.observe(chrome_cid)
            if not self.verify_chrome_context(initial, chrome):
                raise FlowError("CHROME_PAGE_CONTEXT_UNVERIFIED")
            self.note("initial_page_verified")
            sent = self.mcc.call("press", "--connection", chrome_cid, "--frame", initial["frameId"],
                                 "--key", "Cmd+R")
            if sent.get("sent") is not True:
                raise FlowError("FULL_REFRESH_NOT_SENT")
            self.note("full_document_refresh", key="Cmd+R", cache_cleared=False)
            self.step_delay("full_refresh_sent")
            refreshed, login = self.wait_for_target(chrome_cid, chrome, self.login_labels,
                                                    chrome=True, prior_frames={initial["frameId"]})
            before = self.windows(CHROME)
            current_chrome = next((w for w in before if w.get("windowId") == chrome.get("windowId")), {})
            if (not self.valid_chrome_window(current_chrome)
                    or not self.verify_chrome_context(refreshed, current_chrome)):
                raise FlowError("CHROME_PAGE_CONTEXT_UNVERIFIED")
            sent = self.mcc.call("click", "--connection", chrome_cid, "--frame", refreshed["frameId"],
                                 "--x", str(login["x"]), "--y", str(login["y"]))
            if sent.get("sent") is not True:
                raise FlowError("LOGIN_CLICK_NOT_SENT")
            self.note("chrome_login_click", label=login["label"], backend="software")
            self.disconnect(chrome_cid)
            chrome_cid = None
            self.step_delay("login_clicked")

            wechat = self.choose_wechat(baseline)
            wechat_cid = self.connect(wechat, str(wechat["bundleId"]))
            self.note("wechat_window_verified")
            self.step_delay("wechat_connected")
            frame, allow = self.wait_for_target(wechat_cid, wechat, self.allow_labels, chrome=False)
            if not self.has_wechat_authorization_context(self.texts(frame)):
                raise FlowError("WECHAT_AUTH_CONTEXT_UNVERIFIED")
            sent = self.mcc.call("click", "--connection", wechat_cid, "--frame", frame["frameId"],
                                 "--x", str(allow["x"]), "--y", str(allow["y"]), "--eb")
            if sent.get("sent") is not True or sent.get("eb") is not True:
                raise FlowError("MBC_APPROVAL_NOT_CONFIRMED")
            self.note("wechat_approval_click", label=allow["label"], backend="host-mbc")
            try:
                self.step_delay("wechat_approval_clicked")
                after = self.observe(wechat_cid)
                after_texts = self.texts(after)
                visible_labels = any(item.get("text") in self.allow_labels
                                     for item in after.get("ocr", {}).get("items", [])
                                     if isinstance(item, dict))
                approval_dismissed = (after["frameId"] != frame["frameId"]
                                      and after.get("ocr", {}).get("status") == "ok"
                                      and after.get("ocr", {}).get("truncated") is not True
                                      and self.has_context(after_texts) and not visible_labels)
                self.note("wechat_post_click_observe", "dismissed" if approval_dismissed else "pending")
            except FlowError as exc:
                if exc.code == "FLOW_DEADLINE_EXCEEDED":
                    raise
                self.note("wechat_post_click_observe", "unavailable")
            self.disconnect(wechat_cid)
            wechat_cid = None

            chrome_cid = self.connect(chrome, CHROME)
            self.step_delay("chrome_reconnected")
            final = self.observe(chrome_cid)
            context_ok = self.verify_chrome_context(final, chrome)
            texts = self.texts(final)
            final_ocr_complete = (final.get("ocr", {}).get("status") == "ok"
                                  and final.get("ocr", {}).get("truncated") is not True)
            login_still_visible = any(item.get("text") in self.login_labels
                                      for item in final.get("ocr", {}).get("items", [])
                                      if isinstance(item, dict))
            marker = next((label for label in self.success_labels if label in " ".join(texts)), None)
            verified = (approval_dismissed and context_ok and final_ocr_complete
                        and not login_still_visible and marker is not None)
            self.note("final_chrome_business_state", "verified" if verified else "unverified",
                      success_marker=marker, login_button_absent=not login_still_visible)
            self.disconnect(chrome_cid)
            self.note("final_chrome_release", "released", connected=False)
            chrome_cid = None
            return {"status": "verified" if verified else "pending_unverified", "trace": self.trace}
        except FlowError as exc:
            self.note("stopped", "failed", code=exc.code)
            return {"status": "failed", "error": {"code": exc.code}, "trace": self.trace}
        finally:
            for cid in (wechat_cid, chrome_cid):
                if cid and cid in self.owned and cid not in self.disconnect_attempted:
                    try:
                        self.disconnect(cid)
                    except FlowError:
                        pass


def plan(args: argparse.Namespace | None = None) -> dict:
    step_delay = getattr(args, "step_delay", 1.5)
    poll_interval = getattr(args, "poll_interval", 1.0)
    return {"status": "plan_only", "calls_mcc": False, "steps": [
        "status: stop if any MCC connection is already active",
        "find exactly one existing Chrome 视频号助手 window; never navigate another tab",
        f"wait --step-delay {step_delay:g} seconds between key stages; use --poll-interval {poll_interval:g} for read-only polling",
        "observe top-address-bar OCR/page context, then press Cmd+R for full document refresh (not cache clear)",
        "poll fresh OCR frames; click one exact high-confidence 微信快捷登录 target with software MCC",
        "disconnect Chrome; wait only for a new unique WeChat auth window (or explicit manual window ID); click 允许 (also accepts 允许登录) via click --eb (Host MBC)",
        "observe WeChat and reconnect Chrome for business-state verification, then release the Chrome control connection without closing the browser; otherwise pending_unverified",
        "enforce a total deadline; finally disconnect only connections created by this flow on exceptional paths",
    ]}


def main(argv: Sequence[str] | None = None, runner: Callable = subprocess_runner) -> int:
    args = parse_args(argv)
    if not args.execute:
        print(json.dumps(plan(args), ensure_ascii=False))
        return 0
    result = Flow(args, runner=runner).execute()
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result.get("status") == "verified" else 2


if __name__ == "__main__":
    sys.exit(main())
