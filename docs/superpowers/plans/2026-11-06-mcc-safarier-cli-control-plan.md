# Safarier CLI control implementation plan

> **For agentic workers:** Use subagent-driven-development task by task. Terra implements; main alone performs every code review. User instructions override automatic reviewer dispatch, commits and worktree cleanup.

**Goal:** Operate one owned Safarier webpage through MCC-style CLI calls while the Manager remains usable.

**Architecture:** Short CLI clients talk to one authenticated private controller. That controller holds the original native Apple Event sender identity and routes typed requests to the existing Manager, Binder channel and native page executor.

**Tech Stack:** Existing Swift Package, Foundation/AppKit for observation, native Apple Event C APIs, Darwin private Unix sockets, existing Core protocol and native WebView input.

**Spec:** `docs/superpowers/specs/2026-11-06-mcc-safarier-cli-control-design.md`

## Global constraints

- Branch `mcc-safarier`; preserve all pre-existing dirty work and the running user Manager.
- Terra implements; main alone reviews. No commit, install, push, merge or release.
- No global input, PID routing, DOM event simulation, wheel enablement or CAPTCHA automation.
- Original 30/45/5/2-second navigation/lifetime/action/cleanup limits and real identity/cleanup proofs remain.
- Help/invalid arguments do not create runtime/workspace files or launch GUI processes.
- Command spellings are `daemon start|serve|stop`, `mouseDown` and `mouseUp`. Stop requires sessions already confirmed closed and no uncertain or in-flight operation; it does not close the Manager or force cleanup. After the finite 256-entry replay window fills, complete real cleanup before stopping and restarting the controller; the Binder 45-second lifetime is not renewed.

## Task 1: Pure CLI grammar and framing

**Files:** Create `Sources/SafarierCore/ControlCommand.swift`, `ControlProtocol.swift`, `Tests/SafarierCoreTests/ControlCommandCases.swift`, `scripts/automation-core-tests/ControlMain.swift`, `scripts/test-control-cli.sh`.

**Interfaces:** `ControlCLIParser.parse([String]) throws -> ParsedControlCommand`, containing `ControlOptions(applicationPath:runtimePath:)` and `ControlOperation`. Native navigation uses distinct `pressEnterAndWait` and `clickAndWait` operations; existing press/click cases do not change.

- [x] Write focused executable cases for help purity, UUID/path/numeric/option rejection, text redaction/limits, exact frame/JSON boundaries and native-wait flag restrictions.
- [x] Implement the strict parser and canonical IPC request/reply codec; no AppKit imports or filesystem side effects.
- [x] Run `bash scripts/test-control-cli.sh`; main reads the actual API, tests and complete diff before integration.

Proposed usage, not an assertion of current availability:

```sh
safarier control --help
safarier control connect --profile PROFILE_UUID
safarier control observe --connection CONNECTION_UUID
safarier control click --connection CONNECTION_UUID --frame FRAME_UUID --x 200 --y 100
safarier control type --connection CONNECTION_UUID --frame FRAME_UUID --text-stdin
safarier control press --connection CONNECTION_UUID --frame FRAME_UUID --key Enter --wait-navigation
safarier control disconnect --connection CONNECTION_UUID
```

## Task 2: Persistent controller and native transport

**Files:** Create `Sources/Safarier/Automation/ControlCLI.swift`, `ControlDaemon.swift`, `ControlRuntime.swift`, `ControlAppleEventClient.swift`, `Sources/SafarierControlSupport/ControlSupport.c` and its public header. Modify only the required target/dependency entries in `Package.swift` and the early namespace dispatch in `ManagerCLI.swift`.

**Interfaces:** `ControlCLI.run([String]) -> Int32` is called before `SafarierWorkspace.default()`. The controller consumes Task 1 typed operations, retains the actual Manager session token and current target/frame mapping, and returns structured results without secrets.

- [x] Implement private runtime creation/pinning and nonce handshake; authenticate both real kernel peers before command payloads. Verify wrong image/owner/stale instance and oversized frames fail before Manager dispatch.
- [x] Reuse actual native Apple Event semantics for the fixed suite and bundle destination, preserving original Manager sender proof. No OSA or AppleScript source compilation.
- [x] Admit one ordinary operation and reserved reducing operations; preserve input uncertainty and caller ownership. Resolve only actual unique reviewed Manager handles.
- [x] Implement connect/state/observe and frame-scaled native operations; never print the Manager session token or typed text in diagnostics.
- [x] Build/typecheck and run focused headless transport tests. Main reviews the complete new C peer/AE adapter and Swift lifecycle before a read-only live capabilities probe.

## Task 3: Explicit native-input navigation transaction

**Files:** Modify `AutomationProtocol.swift`, `AutomationSessionMachine.swift`, `AutomationRunnerClient.swift`, `AutomationManager.swift`, `RunnerAutomationService.swift`, `BoundRunnerServiceSlot.swift`, `OwnedBrowserAutomationPage.swift` and, only if required, `NavigationCorrelation.swift`. Extend only their relevant existing focused cases.

**Interfaces:** `AutomationNavigationInput.enter` or `.click(point:)`; `AutomationAction.navigateByInput(input:viewVersion:)`; completion is the existing `navigationFinished(viewVersion:)`. The old version is checked before the navigation viewport is incremented.

- [x] Add strict mutually exclusive input schemas and the explicit action/result mapping. Test stale version, held state, out-of-bounds, replay conflict, 30-second navigation deadline and unchanged legacy encoding.
- [x] Refactor the original page navigation workflow to support a native trigger. Hold the actual policy callback until native drain and activity closure; consume one real native root and retain the existing continuation and final input-readiness checks.
- [x] Revoke held callbacks synchronously on cancellation/block/destruction; do not use URL/DOM/metadata as an identity root.
- [x] Run affected focused checks once; parse/typecheck macro variants. Main reviews the combined state-machine and page diff.

## Task 4: Concrete GUI acceptance and delivery

**Files:** Add scoped evidence under `.build/formal-test-app-20261106-001/cli-control-001/` and a canonical verification report under `docs/verification/`.

- [x] Build a new immutable candidate and private runtime root. Main independently checks source inventories, signed app roles/resources, exact artifact hashes and peer/auth changes.
- [x] Probe native capabilities against the existing visible Manager without sending page input or altering profiles. Stop if the CLI registers a duplicate receiver or requires consent.
- [x] If a new Manager binary is required, prepare the exact candidate and preserve the existing Manager. Resolve any necessary user-data/window replacement decision only when the replacement is reviewable.
- [x] Execute the planned separate CLI invocations in one bounded native form scenario; verify input effect, Enter/click navigation and original real cleanup double proof. Collect user concurrency feedback without sending input to another app.
- [x] Record Google CAPTCHA separately; do not infer search success from event delivery. Update the verification and usage docs.
- [x] Main independent review of raw 003/004/005 runtime evidence and PNG.
- [x] Final delivery and current source/artifact integrity closeout; main verified source, artifact pins, cleanup receipts and the visible Manager in `main-final-audit.json`.

## Observed limits

In click-003 the native drain callback arrived before PolicyHeld; the reverse order has not been proven by that run. Google returned a CAPTCHA challenge and search results were not accepted. Earlier enter-002 cleanup failed and remains historical evidence. Enter-004 and daemon-005 have run; main has independently checked their raw evidence and PNG. Final delivery closeout remains pending.
