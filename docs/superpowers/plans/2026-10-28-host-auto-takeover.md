# Host Auto Takeover Implementation Plan

> **For agentic workers:** implement assigned disjoint tasks; code review is reserved to the main agent under AGENTS.md. No worker may review, commit, install, deploy, or modify other files.

**Goal:** Host resumes proven soft pauses on fresh input without a Continue click while preserving hard stops and original countdown/identity gates.
**Architecture:** Extend the existing native pause state and owner-checked daemon reservation; no second executor or public resume endpoint.
**Tech Stack:** Rust 1.89, Swift/AppKit, existing WSS/Unix JSONL.
**Spec:** `docs/superpowers/specs/2026-10-28-host-auto-takeover.md`

## Global constraints
- User-approved boundary in spec; main-agent-only review.
- Installed/remote versions, configs, keys and existing runtime/state untouched.
- Hard pause/uncertainty must win races; do not replay inputs or weaken production timeouts.

### Task 1 — native pause classification and bounded atomic soft resume
- Modify `swift/Input.swift`, `swift/Protocol.swift`, `swift/main.swift`, `swift/ChromeControlToast.swift`.
- Tests `tests/execution-control/main.swift`; use existing library sources excluding swift/main.swift for RED/GREEN.
- Interface: state `hostAutoTakeoverVersion:1`, `pauseReason`; `transport-auto-resume` requires `expectedLease`, `expectedInputEpoch`; response adds `autoResumed:true`, same lease, epoch+1, awaitingCountdown.
- [x] RED tests for soft/manual/transport/stale/overflow/local/countdown + decoder.
- [x] Minimal implementation and native focused GREEN; no real input.

### Task 2 — owner-controlled Rust reservation integration
- Modify `src/native.rs` shared transport sender, `src/daemon.rs` reserve/recovery classification, `src/service.rs` connection/frame eligibility and `src/execution.rs` sanitized reservation intent.
- Maintain no-input query/ownership semantics and old helper failure closed.
- [x] RED daemon/service tests for soft auto takeover and hard/invalid/new-sequence limits.
- [x] Implement receipt validation and same-lease epoch refresh; keep actual input execution unchanged.

### Task 3 — fixtures, end-to-end boundaries, docs and validation
- Existing fake-helper fixtures opt in to new capabilities for positive cases; unknown capability retains old conservative rejection.
- [x] Add real-loopback Host/client tests with fake Native for fresh soft recovery and explicit hard stop.
- [x] Update --help/USAGE/REMOTE-HOST, bump candidate 0.3.6.
- [x] Main-only review full diff; serial Rust full suite, fmt/Clippy, full native BDD/JSONL, build/package/install temp smoke and release WSS process tests.
- [x] Report actual evidence and live UI/deployment limits separately; leave changes uncommitted unless requested.
