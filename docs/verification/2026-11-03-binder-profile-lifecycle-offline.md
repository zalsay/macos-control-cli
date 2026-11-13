# Offline Profile lifecycle verification

## Scope and evidence

Worker implementation is confined to `.build/automation-binder-profile-20261103/worker/`; the formal design and plan are the two companion `docs/superpowers/` files. `frozen-source-sha256.txt` identifies final harness, helper and builder sources; `shasum -a 256 -c` passed. The final actor is reused from the previous staged implementation; the actual Profile/RunnerLaunchSpec/RunnerPreparationPlan source files and original C collector/inventory are read only. A fresh comparison against `before.json` found 0 mismatches among 295 frozen project files and 365 prior-stage files; the main agent owns the complete final audit. No whole-core import or credential/profile repository read was added.

Each batch built and ad-hoc-signed all its fresh CLI fixture roots before serial runs. Final positive and regression fixtures used the unchanged v4 actor and `ProfileBindingTests-before-late-wait.swift`; the final negative fixtures used the same actor with the final helper, which also waits boundedly for the late reader to return. Build commands, flags, object files, signed-root receipts and logs are under the worker. Build entry: `bash worker/make-session-fixture.sh <unique-tag> <flag> <normal|asan>` (run from repository root with full path `.build/automation-binder-profile-20261103/worker/make-session-fixture.sh`); final serial run: `bash .build/automation-binder-profile-20261103/worker/run-v4.sh`. The runner deliberately uses each signed fixture serially and creates no HOME roots while sessions run.

## Preserved RED / failed observations

- `session-red-api-build.log` was a missing `ValidatableRecord`/`RecordRepository` dependency, **not** evidence of target behavior. `session-red-api2-build.log` and `red-api2-source-sha256.txt` record the intended compile RED, missing `bindProfileOnce`.
- `review-red/` freezes the original worker revision. `run-deadline-red-v3.log` exercises a bounded test barrier against that revision and records `test=profile-timeout verdict=FAIL bounded=false`; the old reader awaited a noncooperative continuation past the deadline. The original `AutomationChannelDeadline.run` uses a structured group and alone cannot bound that reader.
- `FullHarness-no-profile-equality.swift`, `ProfileBindingTests-mutant.swift`, `mutation2-source-sha256.txt` and `run-mutationred2.log` / `run-mutationredasan2.log` retain a test-only variant with initial Profile equality removed. Both record `MUTANT_DETECTED profile mutation was accepted`; these are intentional negative mutation results, not production code.
- `review-fix-v3/` and `run-v3normal-*.log` preserve the intermediate regression: checking the live peer after EOF produced `verification-drain-post-io` after normal child exit, and normal runs exited 78. The final revision retains kernel verification before shutdown and uses the retained owned child exit observation after EOF; it does not alter original ControlState finish semantics.
- Aborted build batches and their original receipts/logs remain in the worker; they were not counted as successful runs.

## Final worker results

All counts below are separate process invocations; expected negative controller runs end with exit 78 and count only with the named PASS/closed evidence, not merely the exit code. `run-v4-summary.log` and the corresponding `run-*.log` provide exact results.

| Category | Runs and result |
| --- | --- |
| Original unbound identity/ping/finish | normal 3/3 plus ASan 1/1, exit 0 and controller `identity=true ping=true finished=true childExited=true guiReady=false` |
| Bound Profile through identity/ping/finish | normal 3/3 plus ASan 1/1, exit 0; each log has two `profile-data-bound` markers, one per authenticated endpoint, and the same finished/child-exit markers |
| Profile deny/closure | 14 cases × normal and ASan = 28/28 named PASS and `laterClosed=true`: default, legacy, duplicate, same-first-64-bit UUID mismatch, invalid name, invalid language, initial mutation, later mutation, rebind, pending rebind, cancellation, timeout, cooperative cancellation, unavailable GUI provider |
| Resource mutation | normal and ASan each `test=resource verdict=PASS changed=true laterClosed=true` |
| Peer exit | normal and ASan each `test=lifecycle verdict=PASS firstRejected=true laterClosed=true` |
| Owned cleanup with fresh process proof | normal and ASan: retained owner exited after requested termination, `freshProof=true` |
| Cleanup without fresh proof | normal and ASan: `cleanup_unconfirmed`, `terminationRequested=false`, followed by separately observed natural owned-child exit; not described as successful verified termination |

No `ERROR: AddressSanitizer` or `SUMMARY: AddressSanitizer` marker appeared in the final v4/v5 logs. This is a focused fixture result, not exhaustive memory-safety evidence. Cancellation/timeout fixture returns before releasing the uncooperative test reader, then waits boundedly until the late reader resumes and reaches its return boundary, and verifies the connection remains closed. The cooperative case observes task cancellation. An actually noncooperative reader cannot be forcibly interrupted and may retain its captures plus one completion object for at most the one outstanding reader on that closed connection until it returns or the process exits; this does not prove absence of leaks.

## Main-agent independent verification (separate from worker counts)

`main-review/summary.json` and `results.json` record **62/62 current-implementation checks passed**: 4 unbound, 4 both-bound, 40 independent main-written field cases (32 normal, 8 ASan), 8 pending/cancel/timeout/cooperative cases, and 6 resource/peer-exit/no-proof cases. The 8 positive invocations exited 0; the 54 negative cases had their named PASS/closed or cleanup expectations and exited 78. These counts are not added to the worker table. The main agent’s formal review at `.build/automation-binder-profile-20261103/main-code-review.json` accepts the offline scope with no unresolved findings in that scope; this is not GUI acceptance.

An additional initial ASan invocation aborted with exit -6 because `detect_leaks=1` is unsupported by this platform runtime, before application entry; it is excluded from the 62. `main-review/initial-runtime-option-failure-results.json` and `runtime-option-correction.json` preserve the failure and rationale. The correction removed that option while retaining `halt_on_error=1`; it reused the same signed images without rebuilding, and the first three normal passes were reused, not rerun. No leak-freedom claim follows.

`main-review/no-gui-and-reuse-audit.json` passes the scoped direct dependency/symbol and reuse checks: no direct GUI/input/permission/LaunchServices matches or normal test hooks, one each of the three named collectors, resource/identity bridge and test-helper files identical, and owned cleanup verbatim. The audit’s initial byte-identity assumption for `module.modulemap` was corrected: only the relative header path changed and it resolves to the same frozen original header. The initial audit evidence and correction remain preserved. This direct inspection is not transitive dependency proof or evidence of a real GUI run.

## Historical source mapping

`worker/historical-source-archive/digest-index.json` indexes the six relevant previous-stage baseline files and all 54 entries in `main-review/historical-source-mapping.json`. Nine unique source versions whose recorded original paths no longer matched were recovered from the original staged source or this session’s exact command text and archived **only after matching their recorded SHA-256**. All 54 mapped entries now resolve to a verified same-digest file; original manifests, logs, final source and previous stage were not modified. This is coverage of that mapping only, not a claim that every historical source outside it was preserved.

## Boundary and pending acceptance

Both peers bind matching local fixtures without a new authenticated on-wire Profile attestation. Data-only Profile binding does **not** prove actual Profile/GUI binding, launch or repository provenance, repository freshness, a held lock, GUI/window ownership or human consent. Live GUI capture is unavailable and denies/poisons; there is no injectable approving provider. No GUI/AppKit/WebKit instances, AppleEvents, TCC, Keychain, LocalAuthentication, global input, VM, installation or real/candidate app launch were used. There is no new wire protocol. G1, G5, fullP1, input, shipping, liveAdapter, GUIExecutionAuthorized, manualGrant, ready and armed remain false. No GUI acceptance, release, commit or push is claimed. Main-agent independent results and offline review are reported separately above; final preservation is governed by `.build/automation-binder-profile-20261103/main-final-audit.json`, which this report does not replace. Separately authorized GUI acceptance remains pending.


## Main-agent final review addendum

The 62 accepted checks above are retained unchanged. Main independently built two additional pure CLI fixtures and reran the 40 Profile field/policy negative invocations (32 normal and 8 ASan) with exact expected exception types in `main-review/domain-cause/MainProfileDomainTests.swift`. All 40 matched `ControlFailure`, `ProfileValidationError` or `RunnerPreparationError` as appropriate and stayed closed; a controller identity/transport failure would fail that oracle. Endpoint peer-identity rejection after the controller deliberately closes is not the controller Profile rejection cause. Exact results are in `main-review/domain-cause/results.json` and `summary.json`. These are stronger cause rechecks, not 40 new feature cases; the main total is 62 accepted checks plus 40 cause rechecks, separate from worker runs and the excluded unsupported-ASan-option attempt. Implementation source did not change. Main owns this final review addendum; final preservation is governed by `main-final-audit.json`.
