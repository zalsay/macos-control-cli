# Jev OCR Click Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. User override: code review is performed by the primary agent only.

**Goal:** One semantic click command selects an OCR item with Jev, reuses controlled click, and returns a truthful dispatch receipt.

**Architecture:** Existing service mutex owns observe/select/click as one operation. A bounded HTTPS decision client is injected for tests. Native click accepts an optional trusted OCR guard, verifies it after takeover/motion and preserves existing input checks.

**Tech Stack:** Rust + serde/serde_json, system curl, Swift/AppKit/Vision/ScreenCaptureKit.

**Spec:** docs/superpowers/specs/2026-10-26-jev-click-target.md

## Global Constraints
- Existing commands, protocol v1, window/connection/frame identity and cancellation behavior stay compatible.
- Never persist/log/return API keys; never send them to Swift; no HTTP or input retries.
- Scope is one visible-text click, not an autonomous agent or business-outcome verifier.
- Primary agent alone performs code review; no commits/push/install requested.

### Task 1: CLI contract and credentials
Files: src/args.rs, src/main.rs, tests/mcc.rs.
- [x] Write parser/process regression tests for command, --jev-key, validation, missing key before startup, legacy help.
- [x] Run tests red, implement parsing/env precedence and redacted Debug, run green.

### Task 2: Bounded HTTPS transport (independent worker)
Files: src/jev.rs, src/lib.rs (primary wiring).
Interface: Decision: Send::decide(&mut self,key:&str,request:&Value)->Result<Value>; JevClient; resolve_key(explicit,environment).
- [x] Write failing tests; implement stdin-only curl auth, bounded IO/cleanup/error sanitization; validate with fake executables, no live API.

### Task 3: Target selection and guarded existing click
Files: src/target.rs, src/service.rs, swift/Protocol.swift, swift/Input.swift, swift/Capture.swift, swift/main.swift, tests/text-target/main.swift, tests/native-smoke.sh.
Interfaces: target selection constructs Choice+Noul from validated OCR; service executes one locked action with injected Decision; native optional textGuard checks OCR/epoch before mouse-down.
- [x] Write failing selection/service tests, implement conservative validation and orchestration, run green.
- [x] Write failing native guard fixtures, implement optional guarded-click capture and epoch binding, run green.
- [x] Prove unsafe/changed/unavailable/paused paths never dispatch; prove raw key absent from native requests and receipts.

### Task 4: Integration, documentation and primary review
Files: README.md, README.zh-CN.md, USAGE.md, docs/AGENT-INTEGRATION.md, docs/JEV-CLICK-TARGET.md.
- [x] Add usage/security/cloud/receipt/freshness/uncalibrated-threshold limitations.
- [x] Run cargo test --locked --offline, native smoke, formatting and diff checks; build package without installing.
- [x] Primary inspect complete diff; report exact tests and live-API/real-desktop gaps. No commit/push/install.

## Execution notes
- Reused the clean checkout; branch codex/jev-click-target, baseline d8165e1. No new worktree or commits.
- Primary performed all code review. Worker ownership was only src/jev.rs implementation/tests.
- Primary review fix: cancel model transport via existing daemon stopping signal (network budget8s > daemon stop budget5s).
- Primary review fix: internal guard observe must not overwrite the visible click operation toast.
- Native guard snapshot parsing bounds inputEpoch to exact JSON integer precision, avoiding NSNumber/Int64 overflow.
- Native final smoke: 28 text-guard checks plus existing BDD and 153 no-side-effect JSONL checks passed.
- No live Jev API or real GUI click has been performed; no installed command replaced.
- Final Rust:126 tests passed. Build/package smoke and temporary-prefix 0.2.4->0.2.5 upgrade smoke passed; detailed limits in docs/JEV-VERIFICATION.md.
