# MCC JSON Script Implementation Plan

> Execute inline with executing-plans; primary agent owns implementation and review.

**Goal:** Local MCC and authenticated Host execute one JSON file containing multiple existing operations, including per-step ESP BLE.
**Architecture:** A pure script parser validates bounded JSON. Service orchestrates existing actions under one lock, epoch and cancellation context; existing remote execution transmits one script request and caches bounded progress.
**Tech Stack:** Rust, serde_json, existing Swift BLE executor unchanged.
**Spec:** docs/superpowers/specs/2026-11-17-json-script-design.md

## Global Constraints

- No full regression suite; only touched code checks.
- No delegated review; preserve unrelated dirty files.
- Reuse existing input and Host authentication/ownership paths; no arbitrary shell.
- Script <=32KiB, <=64 steps, <=10s explicit waits, <=40s shared execution deadline.
- Only source/build verification; no installation, push, release or deployment.

### Task 1: JSON/CLI validation
- [x] Add `tests/script.rs` exercising `args::parse_for_scope` with real temp JSON files and `remote::protocol::validate_action` for direct requests. Confirm scripts rejected on current code.
- [x] Add `src/script.rs` for bounded file read, plan parsing and validation. Add CLI `script` options using existing Request dispatch; inline local JSON on remote too. Declare remote.script.v1 capability and validate required capabilities of steps.
- [x] Run `cargo test --locked --test script` (parser tests).

### Task 2: Existing Service orchestration
- [x] Add tests in tests/behavior.rs for frame inheritance, per-step eb selection, whole-file validation, stop-on-failure, pause and wait interruption. Confirm failures before implementation.
- [x] Add Service script execution reusing execute/observe/input/click_target and existing epoch/cancel checks. Use the existing wire validator for static step preflight and keep dynamic input validation in the original executor. Resolve models using existing preprocessing. Add bounded progress projection shared with remote receipts.
- [x] Add scoped real Helper deadline test, then implement remaining-deadline support in Native/Helper and reset after script. Run only script-related tests.

### Task 3: Host integration and replay
- [x] Add real WSS test using existing ProcessGuard; assert one script request, mixed eb routing, latest-frame reuse, owner exclusion, failure progress and no replay. Watch it fail.
- [x] Permit script at existing protocol/service boundaries, register final frames on success/failure, extend typed receipt projection without leaking input text or Host paths, preserve original error codes/partial native receipts.
- [x] Run script WSS tests and focused receipt/owner checks.

### Task 4: Docs/build/review
- [x] Document JSON examples, CLI/help, limits, coordinate units and per-step eb mapping; test help has no file/BLE/runtime side effects.
- [x] Build `bash build.sh debug`, run scoped package preview if needed, inspect full diff as primary agent.
- [x] Report exact validation and hardware limits. Leave source branch reviewable without installation/push.


## Verification evidence

- Focused JSON/parser/progress, Service, native deadline/epoch, local CLI, WSS Host and typed-cache tests passed; no real desktop or BLE input was used.
- Touched help, remote argument/protocol, receipt projection and status, per-operation ESP, Host soft-pause and daemon cancellation checks passed.
- Main-agent review fixed preflight failure-index projection, initial-frame registration/replay, last-step cancellation progress, and local script epoch pinning/reset.
- Full macOS debug package built with Rust, Swift helper and bundled MBC. No installation, commit, push or service restart.
- No full regression suite was run. Hardware/UI acceptance remains outside this source-only task.
