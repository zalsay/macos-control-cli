# Binder writeQueue offline implementation — bounded worker evidence

**Current frozen source: 017. Main verified 112 CLI calls plus 4 separate compile checks; the 008/009 sections below are historical and superseded, not current acceptance.**

Date: 2026-11-04. Scope is an isolated offline fixture, **not product source promotion or acceptance**. Approved base: `2f32d21248deaffd8c8c1152a39912aa46350c7e`; source copied from `.build/automation-binder-v1-context-20261104/worker/attempt-014/src`. The human-approved contract is `.build/automation-binder-writequeue-impl-20261104/contract.md`. All attempt paths below are under `.build/automation-binder-writequeue-impl-20261104/worker/`.

## Baseline behavior RED

- `attempt-003/head-red.log`, `.command.json`, `.exit` and `source.sha256`: actual C/provider/original lock and signed direct CLI; after ready-before the scheduling hook mutated the real repository at the old queue entry. The parent decoded a complete 225-byte stale ready with the original codec. Original ready-after then reported `repositoryChanged`; child exit was confirmed. The targeted old-behavior assertion intentionally returned 1.
- `attempt-003/retry-red.log`, corresponding command/exit and source hash: actual first `Darwin.write` wrote 64 of 229 framed bytes; the observer then mutated the real repository. The old retry loop emitted the complete 225-byte valid stale ready before ready-after detected `repositoryChanged`. Child exit confirmed, targeted assertion returned 1. The 64-byte cap and mutation are explicitly test instrumentation, not authentication.
- `attempt-002/baseline-normal.log` is historical readiness-instrumented exploratory evidence: two frames reserved 120472 bytes and B was emitted after repository mutation. It is not counted as accepted actual-A/B backlog proof; the independent 017 raw-peer A/B cases below are the applicable A/B evidence.

## Historical 008/009 candidates and focused runtime results (superseded)

`attempt-008/src` is the frozen candidate used for all six results below (`source.prebuild.sha256` and `source.sha256`). Only `AutomationChannel.swift` and `AutomationRunnerServer.swift` differ from the 014 source snapshot; all other copied source files including C/provider/model/lock were byte-compared equal. Server-minted `FixtureWriterBinding` / `SealedWriteAdmission` feed `installFixtureWriter(_:)`, `sendBound(_:)`, and actor `validateOwnedQueuedWrite(_:)`. Existing send routes are retained for unbound channels. Main must independently review implementation, especially lifetime, close, locking, one-shot, deadline and first-cause behavior.

Command: `python3 .build/automation-binder-writequeue-impl-20261104/worker/attempt-008/run.py`. Six independent signed direct CLI cases were built and strictly signature-verified before runtime. For each the exact executable invocation and result are in `run-<variant>-<mode>.command.json`, `.log`, and `.exit`; `fixtures.json` records executable hashes. `normal` and `asan` use actual C; ASan build uses compiler address sanitizers and `ASAN_OPTIONS=halt_on_error=1` (not a leak-freedom claim).

| Build | Mode | Observed |
| --- | --- | --- |
| normal | normal | exit 0; original V1 handshake, two unavailable replies, clean status 0, owned child exited |
| normal | head-red | exit 0; real repository mutation at head, queue-attempt `repositoryChanged`, no full ready, boundary EOF, child exited |
| normal | retry-red | exit 0; real first 64/229-byte write, real repository mutation, queue-attempt `repositoryChanged`, truncated frame, child exited |
| asan | normal | exit 0; original V1 handshake and two replies, clean status 0, child exited |
| asan | head-red | exit 0; actual repository denial, no complete ready, boundary EOF, child exited |
| asan | retry-red | exit 0; actual first 64-byte write, repository denial, truncated frame, child exited |

`attempt-009/src` adds only `TEST_ONLY_BOUND_OBSERVABILITY` scheduling instrumentation to 008: actor `holdNextWriteForTest()` returns `FixtureWriteScheduleProbe`, whose `capturedAdmission()` exposes an actual server-minted admission and `release()` resumes scheduling without authorizing it. `lastMintedWriteForTest()` and `pendingSendBytesForTest()` expose observation. `attempt-009/compile-baseline.exit` is 0 with the test flags; this newer candidate **has not been runtime tested**, and 008 runtime evidence cannot be transferred as a test result. It is intended to support main's independent foreign/duplicate tests.

## Failures and remaining gates

`attempt-007/run-normal-normal.log` recorded a real crash: `AutomationChannel.deinit` indirectly captured `self` in asynchronous queue cleanup; child exit was confirmed as signal 6. No subsequent 007 cases ran. Attempt 008 changed deinit and reran all six cases as above. `attempt-006/prepare-failed.full.log` records a pre-build harness preparation assertion (three textual matches rather than one); it was not a behavioral RED. An earlier 004 copy-path typo is recorded in `attempt-004/copy-error.*`.

At the time of the worker-only 008 batch, the following had not been demonstrated by that batch: candidate A/B queue backlog, original lock mutation at head/retry, EINTR, cancellation/late-validator races, FIFO and accounting under saturation, ready/response/diagnostic phase transitions, timeout cap correctness under blocking, foreign and duplicate admissions, live weak-binding loss, legacy aliases or full existing unbound compatibility, compile-negative construction, independent source review, or independent regression suite. See the separate final 017 evidence below for the cases subsequently exercised; absence of universal proof remains explicit. Point-in-time checks do not establish atomic authorization across a subsequent syscall, and bytes emitted before denial cannot be recalled.

No GUI, TCC, global input, installed app, whole-project build, product source promotion, commit, push or release was performed. `fullP1`, `G1`, `G5`, `input`, `shipping`, `liveAdapter`, `GUIExecutionAuthorized`, `manualGrant`, `GUIReady`, `ready` and `armed` remain false.

## Main review corrections and subsequent candidate

Main's `main-review/review-008.md` identified four required changes: unify legacy and bound sends under one queue/head/physical write primitive; reject bound legacy aliases before payload validation; synchronously recheck the same revocation record outside the channel lock before a physical attempt; and capture response/diagnostic send deadlines before server queue and presend waits. Attempts 010–012 preserve those corrections separately from the 008 runtime evidence. Attempt 010's source-generation assertion failed before any source change; its command/log/exit and source snapshot are retained in that attempt.

`attempt-012/src` was the candidate at that historical worker update; it has since been superseded by 017. Bound and unbound frames now share `WriteJob`, one `writeQueue` FIFO and `physicalWriteAttempt` (one `Darwin.write` source occurrence); an unbound job uses no fixture authorization, and bound jobs additionally re-enter the actual server per attempt. The server's response admission is created when the encoded response enters `queuedWrites`, and the diagnostic admission before its remaining presend check. The deadline timer is armed from that same admission at creation rather than after it reaches the channel; ready retains the original handshake deadline. Test-only interfaces from attempt 009 remain available. These are implementation descriptions, not independent review or proof of all race properties.

Fresh compile evidence: `attempt-012/compile-baseline.command.json` / `.exit` compiled with test flags, and `attempt-012/compile-no-test-flags.command.json` / `.exit` compiled the bounded actual source without test flags; both exit 0. `attempt-012/source.sha256` records the frozen sources. **No attempt-012 runtime or ASan run has yet been performed**; 008's six cases do not establish a pass for 012. At that time main-side independent review and runtime regressions were still required; see the later 017 evidence and limits below. Worker did not start a new HOME runtime batch after releasing the prior coordination window to main.

## Main review follow-up: frozen attempt 013

Main's `main-review/review-012.md` requested two further same-path corrections. `attempt-013/src` differs from `attempt-012/src` only in `AutomationChannel.swift`: successful completion schedules the next FIFO head asynchronously on the existing `writeQueue`, avoiding one synchronous stack frame per queued unbound job; and `errno` is captured immediately after `Darwin.write` inside the same `withUnsafeBytes` closure, before returning through Foundation or closing the duplicated descriptor. The existing `TEST_ONLY_READY_RED` hooks and `TEST_ONLY_BOUND_OBSERVABILITY` APIs are retained unchanged.

Bounded compilation of attempt 013 passed with test flags (`compile-baseline.exit` 0) and without test flags (`compile-no-test-flags.exit` 0). Exact compile commands/logs and frozen source SHA are in `attempt-013/`. No attempt-013 HOME case, signing, runtime, ASan run, or independent acceptance was performed by the worker; main owns the next independent runtime window. Earlier runtime evidence applies only to the candidate on which it was obtained.

## Attempt 014: validator cancellation hint and late-result instrumentation

At main's request, `attempt-014/src` adds a queue-owned handle for the actual detached validator task. Terminal settlement calls `cancel()` as a hint and clears the handle; no path awaits the validator task, and the existing exact-head/receipt fence remains in the queue callback.

Under `TEST_ONLY_BOUND_OBSERVABILITY`, `AutomationRunnerServer.holdNextPostFixtureCheckForTest(ignoreCancellation:)` installs a one-shot scheduling probe after the real `fixtureCheck` returns and before the validator's existing post-check guards. `AutomationChannel.holdNextValidatorResultForTest(ignoreCancellation:)` installs a one-shot probe after the real validator returns success or failure, before its queue callback. Both return `FixtureValidationScheduleProbe`: `capturedAdmission()` and `capturedResult()` expose observed facts; `release()` releases the pause; `counts()` returns hold/callback/discarded counters. The optional cancellation-ignoring behavior exists only in the compile-guarded probe; it does not substitute or alter authorization results. The prior presend `FixtureWriteScheduleProbe` API remains unchanged.

The bounded test-flag and no-test-flag compiles of 014 both exited 0; exact commands, logs, exits and source SHA are in `attempt-014/`. Worker performed no 014 signing, HOME fixture build, runtime, ASan or late-callback verification. Main's independently reported 013 results do not establish 014 runtime behavior.

## Attempt 015: typed unavailable-only filter failure

`attempt-015/src` retains attempt 014's validator cancellation hint and test probes. Relative to 014 only `AutomationRunnerServer.swift` changes: the existing unavailable-only filter's rejection now records the private typed `FixtureContextFailure.notUnavailable` through the original shared `FixtureRevocation.fail` before stopping, and the actor diagnostic mirrors that same first-cause record. The wire filter and `notUnavailable` diagnostic spelling are unchanged. If a prior terminal cause already won, the shared record remains authoritative.

Bounded test-flag and no-test-flag compiles of 015 both exited 0. Commands, logs, exits and frozen source SHA are in `attempt-015/`. The worker did not build or sign HOME cases or run 015 runtime/ASan tests; the subsequent main independent rerun is documented in the final 017 section below.

## Attempt 016: read-only outstanding-request getter

`attempt-016/src` differs from 015 only by the `TEST_ONLY_BOUND_OBSERVABILITY` actor getter `outstandingRequestsForTest() -> Int`, which returns the existing `tasks.count` for main's deterministic shutdown observation. It neither modifies server state nor supplies an authorization result. Test-flag and no-test-flag bounded compiles both exited 0; exact commands, logs, exits and frozen source SHA are under `attempt-016/`. No worker HOME case, signing, runtime or ASan execution was performed for this attempt. The subsequent main independent 017 runtime is documented below; main's final audit remains pending.

## Attempt 017: failed-install receiver flush

Following main's `main-review/review-016.md`, `attempt-017/src` differs from 016 only in `AutomationChannel.installFixtureWriter(_:)`: its invalid-install branch now calls the receiver's `close()` after releasing the channel lock, then throws. This schedules the existing failed-job flush and validator cancellation hints; it does not operate on a foreign binding or its owner. Bounded compiles with and without test flags both exited 0; commands, logs, exits and source SHA are under `attempt-017/`. No worker HOME fixture, signing, runtime or ASan execution was performed for 017. At that time, main's full final rerun and held-validator rebind/foreign-install case were pending; see the final 017 evidence below.


## Main independent final verification: attempt 017

**Final tested frozen source:** `.build/automation-binder-writequeue-impl-20261104/worker/attempt-017/src` (not product `Sources`). Channel SHA-256 `9917ebfd05d1dcd9a8cd5542987cb469bbbfd273c646f0d4add328d7cd527c06`; server SHA-256 `78c207728992a5f61faebc251b53266666d44f10de685c7867cc1b2ebd8f6760`. Main's normal/ASan evidence reports source unchanged within each suite. All signed cases were constructed before the pinned runtime runs; owned-child cleanup is reported in the individual evidence.

**112 top-level CLI calls passed** (normal and ASan combined, no historical runs added):

| Evidence | Count | Scope and classification |
| --- | ---: | --- |
| `main-review/all-final-final017-summary.json` and `all-final-final017-results.json` | 78 | Signed/direct actual-fixture suites: 34 bound (including two expected DYLD refusals), 10 init, 30 own-queue, 4 actual A/B. Expected refusal/denial is a passing negative assertion, not business success. |
| `main-review/mechanics-final017-summary.json` | 30 | 24 seam + 6 legacy mechanics; its summary explicitly says these are not actual kernel-context tests. |
| `main-review/budget-final017/summary.json` | 4 | Actual legacy byte-budget/error-compatibility cases, including eight tiny jobs behind a blocked large job and exact 262160-byte budget; not kernel-authorization proof. |

Additional `main-review/private-api-final017/summary.json` records **four compile checks**, all passed, for constructor inaccessibility, payload/deadline immutability, and positive read access. They are **not runtime calls or behavior REDs** and are not included in 112. Main's earlier 013 100 calls, unused signed 016 fixtures, worker 008 six cases, historical baselines and REDs are likewise excluded from 112.

### Behavioral RED/GREEN and focused observations

- **Original ready-head/retry behavior RED:** worker `attempt-003/head-red.*` and `retry-red.*` show actual C/provider/original-lock baseline checks, actual repository mutation, and complete valid stale ready emitted by the original queue. In retry, a real 64/229-byte write preceded the mutation. These are readiness/scheduling-instrumented original-code cases, not compile failures. Main's 017 own-queue direct head/retry GREEN cases are under `main-review/queue-final017/`: actual repository mutation causes denial before a complete ready; retry may leave already-emitted partial bytes.
- **Held rebind behavior RED → GREEN:** `main-review/rebind-red016-driver.log` and `rebind-red016/` record 016's targeted actual behavior RED: caller did not settle within 600 ms while the actual validator was held after failed rebind. The matching 017 held-rebind case in `main-review/queue-final017/` passed; it is separate from the earlier baseline and not an extra call beyond the 112.
- **Late validation and receiver ownership:** the 30 own-queue cases include foreign and reused admissions, four alias cases including invalid sizes, prequeue expiry/cancel, actual-validation held late-success/late-failure/post-check-cancel, and held-rebind. For the relevant held late-result cases main reports `callbacks=1`, `discarded=1`, `pending=0`. The probes only schedule/observe actual validation; they do not replace it. See `main-review/queue-final017/summary.json` and its per-case command/log/exit artifacts.
- **Actual A/B backpressure:** `main-review/ab-final017/` contains four normal/ASan raw-peer cases. With `SO_SNDBUF=1024`, the peer observed an actual A prefix while pending bytes exceeded 120000. The positive case received A then B intact; the real repository mutation case observed zero B bytes and typed `repositoryChanged`. The first observed denial in that mutation case was **A's `write-after`**, not a demonstrated first denial at B's head. Ready-head and retry direct cases separately exercise those checks. Bytes of A already emitted are not rolled back.

### Remaining boundaries and handoff

True OS-level EINTR fault injection was **not performed**. Point-in-time context checks do not prove atomic authorization through the subsequent syscall; universal syscall/C quiescence or cleanup under every possible OS/C stall is not established. These offline fixtures do not prove controller repository-context integration, full application integration, GUI behavior, TCC/LA/LS permission, production composition or shipping readiness. ASan cases use `halt_on_error=1`; they are not a universal memory- or leak-freedom proof.

The historical tmp-glob/refusal-workaround incident, read-only PID/process-scan incident, and 73-file compiler-cache-scope incident remain unresolved and are not erased by these tests. The earlier read-only first handoff was not completion. No product source promotion, GUI execution, global input, installed-app operation, commit, push, release or deployment is authorized by this evidence. `fullP1`, `G1`, `G5`, `input`, `shipping`, `liveAdapter`, `GUIExecutionAuthorized`, `manualGrant`, `GUIReady`, `ready`, and `armed` remain false. Main alone owns final code/image/provenance/preservation audit and closure.
