# Registered prepare timeout investigation

Baseline: `b690c60`, branch `mcc-safarier`. This investigation changes the existing registered preparation path, its focused tests, and this record. The first phase was offline; the subsequent authorized packaging, restart and live verification are recorded below.

## Failure and cause

The preserved single-tab run in [the prior record](2026-11-13-registered-same-document.md#single-tab-launch-and-failed-connect) failed during preparation, before service creation or page attachment. Its source diagnostics are `/Users/yingzhang/sf-single-tab-20261113-y0mwpqoc/search/diagnosis/profile-metadata.log` and `unified-metadata.log` in the same directory. These are historical live observations, not a new reproduction.

`AutomationLimits.frameSeconds` is currently 6 seconds. `serveAppBound` creates one `FrameDeadline` and passes it through hello, ready and `serveV1Handoff`; preparation cannot restart that budget. The recorded elapsed values give this sequence (rounded):

| Boundary | Elapsed since handshake deadline creation | Remaining frame budget |
| --- | ---: | ---: |
| Before ready | 2.381 s | 3.619 s |
| After ready | 3.883 s | 2.117 s |
| After prepare-before validation | 4.424 s | 1.576 s |
| After App identity validation | 4.967 s | 1.033 s |
| After App profile validation | 5.544 s | 0.456 s |
| Plan validation interrupted | approximately 6.005 s | expired |

The plan phase reported an error after 0.539 s; its log can complete after the channel deadline has already won. Runner generation's first recorded close was `deadlineFailure`; subsequent root teardown and Manager `RUNNER_EXITED` are downstream observations. The page factory and initial-load wait had not been entered, so those paths did not cause this particular preparation failure.

The App previously awaited `validate()`, `validate(profile:)`, and `validate(preparation:)` consecutively before constructing the registered service. Each invokes the same complete `FixtureContext.check`: self identity, bundle resources, actual parent, socket peer, second parent observation and a fresh repository read, with cancellation, revocation and deadline checks. The preparation variant additionally compares profile, launch spec, proxy, subscription and node. Thus the final complete plan validation already covers the earlier two validations' predicates. No page or service side effect occurs between those calls.

This establishes avoidable repeated validation cost inside a fixed shared budget. It does not establish which Security API, I/O or scheduling component caused the historical checks to take approximately 0.54–0.58 s each. The earlier hello EOF signature remains a separate unresolved issue.

## Change and review

`BoundRunnerServiceSlot.prepare` uses the existing complete `validate(preparation:)` once for registered sessions. Existing plan/mode/session guards, live checks, cancellation, single binding, and service identity checks remain. The nonregistered branch still calls `validate()` before resource preparation. Core's hello, ready, queued-write, prepare-before and prepare-after checks, all deadlines, and cleanup paths are unchanged. No cached validation or parallel identity collector was introduced.

The main agent reviewed the source and diff. The relevant containment is in `FixtureContext.check`, `RunnerBinderContext.validate(preparation:)`, `RunnerPreparationPlan`, and `BrowserSession.makeRegisteredAutomationService`: the same profile and dependency comparisons still precede service creation, and subsequent page and permission checks remain independent.

## Focused evidence

Evidence is saved under `.build/takeover-timeout-20261116/` (ignored build output):

- `baseline-focused.log`: existing real-source XCTest selection, 4 tests, 3 passed and 1 failed. `RegisteredPrepareDeadlineTests` delayed 1.6 + 2.0 seconds, which fits the current 6-second frame; it dispatched one handler and then waited for the server's idle timeout. This is a stale test, not evidence that the shared deadline is renewed.
- `preparation-red.log`: new standalone App boundary regression compiled the unchanged real `BoundRunnerServiceSlot.swift` and `RegisteredPrepareTrace.swift` against explicit Core and App doubles. With 400 ms per full validation and 1 second remaining, the old implementation failed at plan validation before binding.
- `preparation-green.log`: the same boundary regression passed after the change. It exercises successful preparation and dispatch within the remaining budget, repeated binding rejection, closed-slot rejection, and identity/profile/dependency/expiration/cancellation/missing-plan/invalid-mode failures before service creation. It also checks that nonregistered preparation still validates before reaching resource preparation. These doubles test App orchestration, not actual process authentication or bundle verification.
- `focused-green.log`: real-source XCTest selection covering registered handoff/EOF, shared preparation deadline and preparation diagnostics: **4 passed, 0 failed**. The deadline test now delays each phase for 65% of `AutomationLimits.frameSeconds`: each fits independently but their sum cannot fit the original frame. A test-only 2-second idle timeout bounds failure feedback if the shared cutoff regresses.
- `deadline-final.log`: after adding the explicit assertion that preparation actually started, the deadline test was rerun alone: **1 passed**, approximately 6.005 seconds, with zero business dispatches. The other three tests were unchanged.

Commands:

```sh
python3 scripts/test-registered-preparation.py
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  -Xswiftc -DSAFARIER_BOUND_LOCAL_CANDIDATE \
  -Xswiftc -DSAFARIER_INTERNAL_TEST_APP \
  --filter 'RegisteredPrepareDeadlineTests|RegisteredGenerationEOFTests|RegisteredPrepareTraceTests'
git diff --check
```

Only this focused selection was run; no full regression suite was run. The Swift build reports existing concurrency warnings in unchanged code. The following live validation supersedes the initial offline-only verification scope; this record does not claim all takeover timeouts or the older EOF issue are fixed.

## Packaging, restart and live verification

The existing `scripts/dsh-runtime/unified-release.py --artifact …` pipeline completed all seven stages, retaining the existing runtime artifact and pins. Build attempt: `.build/automation-bound-control-integration-20261104/formal-test-app-20261106-001/packaging/attempt-20261116-085309-457d24290d86437ba1e02269872111c4`.

The candidate was installed at `/Users/yingzhang/Applications/Safarier AI.app` and copied to `dist/releases/Safarier AI.app`. Main-agent independent review confirmed all 150 source entries matched before/after packaging and the current source, all 12 pins matched both copies, and strict signatures, namespace, metadata and resources passed. The previous installed app remains at `/Users/yingzhang/Applications/.safarier-install-backup-8b5281bd7b2a4f938ebca524cabe249b.noindex/previous.app`; the previous fixed release remains at `dist/releases/.unified-release-backup-20261116-005401-41407b7ee1fe4e3e9b271587ea2cc422.noindex/previous`.

Existing app processes were normally quit after saving session backups, and the installed Manager was restarted. Once startup completed, read-only authorization returned `allowed`. No permissions were reset or admission checks bypassed.

The original failing profile, **新媒体运营** (`9080635F-0A64-4ECC-9969-58C9618B5072`), was launched normally. The first attempt completed preparation but was refused later at page admission: `REGISTERED_ADMISSION_DIAG reason=appActive` / `INTERACTION_REQUIRED`. This is distinct from the preparation timeout. After the user confirmed switching the browser to the background, two fresh complete connect → state → release rounds succeeded against the same Runner, window and page:

| Round | Handshake + preparation | Complete plan validation | Connect wall time | State / release |
| --- | ---: | ---: | ---: | --- |
| 1 | 3.247 s | 466.482 ms | 14.985 s | both `ok` |
| 2 | 1.515 s | 145.023 ms | 8.217 s | both `ok` |

The shared handshake/preparation budget remains **6 seconds**; the full connect wall time covers later work as well. Both release receipts matched their state target and confirmed `inputReleased`, `artifactsCleaned`, `browserRetained` and `manualInteractionEnabled` were all `true`. Manager commit/take-owner logs also reported success. The test issued no page click, typing, observation or navigation commands, and the test daemon was stopped afterward. These two rounds did not reproduce the original preparation timeout.

The two pre-restart environments were relaunched using existing paths: **本地inboard** through Manager and **My** through the ordinary interactive Runner because My has Agent access disabled; that permission remained disabled. Final process inspection confirmed both helpers and Manager running from the installed bundle. My's saved session remained one window / six tabs. 本地inboard's restore diagnostics recorded all three saved tabs restored and final selection; a later saved snapshot contained one tab. The user confirmed manually closing those tabs, explaining the count change; the current session was not overwritten. The original three-tab snapshot remains in `sessions-after-quit/`. Separately, the test browser was absent at a later process inspection; successful release receipts prove retention at release time, not indefinite process survival.

Live evidence is under `.build/takeover-live-20261116/`, including `installed-review.json`, `verified-live-result.json`, `background-confirmed/live-summary.json`, per-round raw results, profile/unified logs, normal-quit/session backups and final running-app metadata. Raw connection material is private build evidence and is not reproduced here. Source changes remain uncommitted; no full regression suite was run.

## Follow-up: remove persistent uncertainty admission blocks

The user subsequently authorized removing the broker's uncertainty-based interception for Agent-enabled environments. `ControlBroker` no longer uses historical `session.uncertain` to reject later explicit state/observe/input/release requests. The global `openingUncertain` flag was removed, so an uncertain open/close result or lost acknowledgement no longer permanently blocks a later connect or an otherwise idle daemon stop. Session uncertainty remains a historical diagnostic only. Requests still reach the existing Manager/Runner permission, identity, target and deadline checks; active requests and pending ACKs still serialize execution. Original errors, request replay protection and release/cleanup proof validation remain intact. No failed action is automatically replayed, and daemon stop is not a release receipt.

Regression evidence is under `.build/control-uncertainty-20261116/`:

- `uncertainty-red.log`: 8 new broker tests ran before the change; 7 failed at the persistent block, while the outstanding-ACK serialization test passed.
- `uncertainty-lifecycle-red.log`: updated lifecycle expectations failed at the old persistent stop restriction (5 assertion failures).
- `uncertainty-green.log`: focused broker admission, acknowledgement, existing observe/input reuse and semantic-click tests: **22 passed, 1 skipped, 0 failures**. The real socket test was skipped because the XCTest host failed the existing peer identity gate; no bypass was introduced.
- `uncertainty-auto-close-green.log`: the broker disconnect-after-automatic-close test, including unconfirmed cleanup, passed with the required `SAFARIER_MANAGER_ROUTING_TESTS` flag: **1 passed**.

The focused commands used `swift test` with `SAFARIER_CONTROL_TESTING`, `SAFARIER_BOUND_LOCAL_CANDIDATE` and `SAFARIER_INTERNAL_TEST_APP`; only the automatic-close test additionally required `SAFARIER_MANAGER_ROUTING_TESTS`. Existing AppKit concurrency warnings remain in unchanged code. The main agent reviewed the production and test diffs and `git diff --check` passed. No full regression suite was run.

At the end of this follow-up, it had not yet been repackaged or installed. The two live success rounds recorded above belong to the preceding preparation-timeout candidate. Subsequent packaging and installation of the admission-policy change together with DSH rc.2 are recorded in [the DSH upgrade record](2026-11-16-dsh-rc2-package.md).
