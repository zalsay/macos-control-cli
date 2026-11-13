# Binder v1 retained runner fixture context — worker verification record

**Status (2026-11-04):** final-source evidence synchronized; candidate `.build/automation-binder-v1-context-20261104/worker/attempt-014/src/` remains fixture-only and unchanged. Main reports its three independent final-014 test groups passed; main alone conducts final audit and closure. Neither these tests nor this document establish production authentication or GUI readiness.

## Provenance and staged APIs

- Contract: `.build/automation-binder-v1-context-20261104/contract.md`; main adjudication and correction requirements: `main-review/design-adjudication.md`, `independent-oracles.md`, `review-findings-011.md`, `review-findings-013.md` under the same task root. Current source manifest: `worker/attempt-014/source.sha256`; current targeted signed fixture manifest: `worker/attempt-014/fixtures.json`.
- Attempt 014 inherits and stages the original v1 seam/channel from seam attempt 019, actual C identity/bridge/bundle-pin and PrivatePair/owned-process fixture lineage from attempt 026, the explicit private-initializer `RepositoryBindingProvider.makeFixture` from composition attempt 002, and repository-040 model/lock support. The private runner context retains its own server's channel-derived nonreading inspector, actual bridge self/parent/peer evidence, same provider and original runner-held `ProfileLock`. Pre-hello cannot prove peer socket last-use; peer capture follows the original hello and precedes ready.
- Copied server fixture APIs: `installFixtureContext(expectedSpec:actualArgs:environment:deadline:) async throws`, `beginV1Handshake(deadline:)`, `sendV1Ready(_:deadline:)`, `serveV1Handoff(_:prepare:)`, actor-isolated read-only `fixtureFailureForTest() -> String?`, and `closeFixtureSetupForTest() async`. The last joins provider/inspector release, not arbitrary noncooperative work. Existing unbound mechanics are not authenticated context. Wire ready is not a GUI or production authorization.
- The controller uses the original owned-child handle and kernel-derived executable path; it does not assert that its own provider holds the runner's lock. No controller-side retained repository snapshot/revalidation is established.

## Actual worker results and classification

Paths in this section are under `.build/automation-binder-v1-context-20261104/worker/`; each attempt contains its own commands, logs and exits. They are worker results only and must not be added to main's independent final-014 count.

| Evidence | Actual result and scope |
|---|---|
| `attempt-001/red.log`, `compile-red.log` | Source-interface assertion and missing-method compiler failures respectively; neither is behavioral/security proof. |
| `attempt-002/behavior-red.log`, `.exit` | Actual C/original-v1 baseline: after first unavailable response and a schema-valid fixture repository mutation, a second unavailable response was still returned; harness intentionally exited 78. Old path did not contain the provider. |
| `attempt-003/run.log`, `.exit` | Channel-only inspector check: CLOEXEC and rejection after channel close; exit 0. Not a peer-identity test. |
| `attempt-005/runtime.log`, `.exit` | Signed setup-only test exited 0: actual C self/parent and provider/lock held-then-released observations; no pre-hello peer assertion and no serving proof. |
| `attempt-012/test-legacy.py` and `run-*.log` | Against earlier **attempt 011**, ChannelTests, V1SeamTests and three legacy modes exited 0. These do not prove final attempt-014 compatibility. |
| `attempt-013/build-run.py`, `run-normal.log`, `.exit` | Both case setup and all four signatures completed before pinned runs. Normal case exited 0: two original v1 capability requests, two unavailable replies, two handler entries, actual C self/parent/peer observations. |
| `attempt-013/run-mutation.log`, `.exit` | Expected denial case: controller changes fixture repository after first response, second response absent, one handler entry, child status 1; typed `RepositoryBindingProvider.Failure.repositoryChanged` was observed at `phase=write-after`. Top-level harness exit 0 means its negative assertion passed, not a positive business operation; the observed phase is not a claim of second-request-admission rejection. |
| `attempt-013/main-seam-foreign-pending.log`, `main-seam-foreign-handoff.log` | Both unchanged main-provided mechanical test drivers exited 0 when worker compiled them against attempt 013. These cover receiving-channel close and preservation of original foreign owner in their unbound test setup; not the complete bound negative matrix. |
| `attempt-013/run-dyld.log`, `.exit` | Expected exit 78 with `HarnessError.environment` for `DYLD_*` input; not a successful operation. |
| `attempt-013/run-forced-error.log`, `.exit` | Expected exit 78 after forced parent error; original owned child was observed exited, no termination requested. Fresh-proof termination and cleanup-unconfirmed branches were not exercised. |
| `attempt-014/install-red.log`, `.exit` | The new install-failure test run against old attempt 013 exited 1 on timeout while waiting for wrong-profile channel closure: a behavior RED, not a compiler failure. |
| `attempt-014/install-green.log`, `.exit` | The same test against attempt 014 exited 0, checking typed wrong-profile failure, terminal channel close, closed-inspector failure and sticky legacy rejection. |
| `attempt-014/bound-handler-race.log`, `.exit` | Main's unchanged deterministic actual-C signed handler-race harness, run by worker against attempt 014, exited 0 after asserting handler-after `repositoryChanged`, no second reply, two handler entries and server status **1**. Main's original attempt-013 run had status 0 and failed, as recorded in `main-review/review-findings-013.md`. |
| `attempt-014/bound-normal.log`, `bound-eof-handler.log`, `bound-cancel-handler.log` | Worker targeted signed cases exited 0: normal and clean peer EOF reported status 0; canceled handler case reported status 1. All fixtures were built and signed before pinned runtime. |
| `attempt-015/test-mechanics.py` and `run-*.log` | Worker compiled unchanged main mechanics driver against attempt 014 and observed exit 0 for pipeline, foreign-pending, foreign-handoff and cancel-before-hello; these are not the full independent matrix. |

No worker attempt-014 ASan result, full project/SwiftPM test, live application, page, GUI or device acceptance is claimed. Main independently ran normal/ASan groups as described below; worker and main counts are not mixed.

## Main independent final-014 verification — 74 top-level CLI calls

These are the exact three independent **top-level CLI call** groups, not 74 distinct test cases. All summaries state `allPassed` and `sourceUnchanged`; main final audit and closure remain separate.

| Summary, under `.build/automation-binder-v1-context-20261104/main-review/` | Calls and boundary |
|---|---|
| `final014-mechanics-summary.json` | **30**: 24 seam and 6 legacy, normal/ASan. Explicitly not actual-kernel-context tests. |
| `bound-independent-014/summary.json` | **34**: 32 actual signed-C bound calls including normal repeats, plus 2 expected-exit-1 DYLD-refusal calls. Actual writeQueue full revalidation remains false. |
| `context-init-final-014r2/summary.json` | **10**: five setup modes in normal/ASan; setup-only, no peer assertion or bound-v1 serving claim. |

The 32 bound calls cover repository bytes, same-content inode replacement, mode and unselected-record mutation; before-ready denial with no ready/preparation; before-preparation denial with zero preparation; deterministic handler-await race with typed post-handler `repositoryChanged`; lock replacement showing the original inode remains held while the replacement pathname is lock-free and that the original later unlocks; cancellation/EOF fencing of late handlers; malformed diagnostic; enabled-outcome refusal; and foreign-token recipient closure while legitimate owner continues. Exact per-program assertions are in the main summary and its `results.json` and logs. An expected-denial test exiting 0 indicates **assertion success, not business success**. Historical baseline 30, setup attempt-005 eight, failed attempt-013 runs and all worker counts above are **not added** to 74.

### Preserved oracle and harness errors

`context-init-final-014/oracle-correction.json` preserves the initial overly restrictive cancellation oracle and its failed logs. A pre-canceled task's cancellation handler closes the channel; `duplicateInspector` may then yield `ChannelError.closed` before C collection. The corrected oracle accepts **only** `CancellationError` or `ChannelError.closed`, and only with `Task.isCancelled`, an explicitly closed channel and no retained lock. The product source was not changed to accommodate the oracle. The separate main harness compile error from omitted `()` when calling `admittedReadersForTest()` is preserved as a harness compile error, **not** a feature behavioral RED.

### Image and reuse evidence

`bound-independent-014/image-audit.json` records a static dependency/undefined-symbol audit of the normal image with no banned UI/global-input/AppleEvent/LaunchServices/Keychain findings, and the existing C collectors present. This is a static image observation, not runtime desktop acceptance. `reuse-014.json` accounts for **29** source files: **26** byte-identical to frozen inputs and **3** reviewed modifications (`AutomationRunnerServer.swift`, `AutomationChannel.swift`, `V1KernelFixture.swift`). These observations do not establish a production security boundary.

## Fixture root and execution-discipline deviations

Main separately precreated a HOME700 root documented in `main-review/fixture-root-authorization.json`, with `workerOwned` and `mainOwned` separated. Attempt 014's `environment.json` records `TMPDIR` and compiler cache under the worker directory; its fixture build script creates only new case namespaces in the authorized `workerOwned` root and constructs all initial workspace files and signatures before pinned runtime. No authority over `mainOwned`, real profiles, or arbitrary HOME roots is implied.

**Unresolved current deviation:** attempts 002–008 used task-root `tmp`/`cache` rather than the required `worker/tmp` and `worker/cache`; attempt 008 compile was in flight when the correction was received. Details and preservation boundary are recorded in `worker/UNIT3-TEMP-PATH-DEVIATION.md`. Subsequent attempts use worker-owned tmp/cache. No cleanup or rewriting of the main-owned directories was authorized or performed as a remedy.

**Unresolved historical incidents:** the prior manual temporary-glob deletion had an unknown pre-delete matching set, and a prior read-only process scan violated its no-scan contract. Their previously recorded impact is not cleared by later code or tests. Preserve original evidence; no deletion, process scan or refusal bypass is authorized here.

## Remaining blockers and unverified requirements

1. **Actual writeQueue gap — production blocker.** Server presend performs full context validation before submitting to `AutomationChannel`'s serial write queue. There is no full identity/repository validation inside that queue at actual dequeue/system write; a queued send can wait after validation, and a post-send failure may follow exposed bytes. This is separate from ordinary last-instruction OS TOCTOU. No new write engine or collector is implemented or authorized. Do not claim full lifetime send authority.
2. Point-in-time C observations do not prove peer identity at the last byte, prevent same-UID descriptor delegation or create atomic cross-file snapshots. A callback, synchronous OS/C operation or filesystem call may not cooperate with cancellation; logical revoke fences later commits, not reversal or guaranteed quiescence. Fixture handlers must remain side-effect-free unavailable handlers apart from counters/barriers; response filtering cannot undo side effects.
3. Main completed the final-014 **74 top-level CLI calls** and its code review in the restricted offline fixture scope; see `.build/automation-binder-v1-context-20261104/main-code-review.json` and the three main summaries above. Final integrity audit and closure remain separate. Main ran normal/ASan verification even though the worker did not run its own final-014 ASan. Blocked/partial actual-writer behavior, universal lifetime and race coverage, and forced TERM/cleanup-unconfirmed behavior in this phase remain unverified; passing the covered matrix does not establish them.
4. Production context/composition, controller-side repository retention, real profiles, app startup, GUI/page/input safety, consent and deployment need separate authorization and evidence. The fixture uses no private additional handshake or second reader and does not enable the product path.

All listed gates remain false: `fullP1`, `G1`, `G5`, `input`, `shipping`, `liveAdapter`, `GUIExecutionAuthorized`, `manualGrant`, `GUIReady`, `ready`, `armed`. No commit, release, installation, production promotion or GUI execution is claimed.
