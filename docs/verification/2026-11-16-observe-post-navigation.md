# Observe after successful navigation: bundle validation timeout

Baseline: `b690c60`, `mcc-safarier`; existing unrelated work is retained. Exact failing observation: `A80C7CAA-AECD-4852-9660-EA2400BD0DE8`. No search or navigation was replayed during this investigation.

## Confirmed failure chain

The preserved unified trace is `.build/registered-ack-20261116/observe-followup.ndjson`. Runner diagnostics are in `~/Library/Application Support/Safarier AI/logs/9080635F-0A64-4ECC-9969-58C9618B5072.log`, around lines 22600–22711. Times below are elapsed from this observe's Manager receipt, avoiding mixing the machine log timezone with the user's timezone.

| Boundary | Elapsed |
| --- | ---: |
| Manager receipt | 0 |
| Runner decoded | 0.765 s |
| Screenshot sink started | 5.800 s |
| Screenshot sink returned success | 6.428 s |
| App handler returned success | 6.760 s |
| Runner closed generation during `handler-after` | 9.907 s |
| Manager returned `INDETERMINATE_RESULT` | 9.909 s |

Runner's exact first failure is `FIXTURE_DENIAL phase=handler-after type=SafarierCore.IdentityBridgeError error=collector("bundle", 2)`. `BB_EXPIRED=2` in `BundleInventory.h`; this is expiration, not `BB_CHANGED=4`. `BundleResourcePin.checked` derives a C deadline capped at 2,999 ms from the original `FrameDeadline`. The final check failed after roughly 3.148 s. The logs locate the expiration inside bundle validation, but do not distinguish its initial inventory, signature validation, main executable pin or final inventory. A blocking OS call and scheduling delay also cannot be distinguished from these old logs.

The screenshot handler succeeded but no `runner.reply.queued` followed. The generation's first close was Runner `fixtureCheck`, then Manager read EOF. The error reply was authenticated through AppleEvents. Thus the original connection and navigation succeeded; this particular lost observation is not an AppleEvent reply loss or proof that the page/navigation failed. Total sequence duration was about 67 seconds, below the 90-second generation limit; it is not evidence of a shared 60-second sequence cutoff.

The subsequent release `E019D1F4-4610-4C29-9D67-F3699CF39431` reached Manager and was immediately rejected as `SESSION_BUSY`. Ordinary-request failure calls `startClose`, moving the entry to `closing`, eventually `closed`. The old release guard combined those terminal states with genuinely active operations. Waiting cannot reactivate such a session. Automatic presentation restore and root teardown do not provide the four-field release receipt, so release remains unconfirmed for the historical run.

## Changes

- `AutomationManager.release` returns `SESSION_EXPIRED` for closing/closed sessions when there is no prior release request. Existing release replay/conflict handling stays first; active work still returns `SESSION_BUSY`. No handshake is dispatched to the failed channel and no release proof is fabricated.
- `bb_revalidate` emits fixed-label duration, remaining C budget and result for `inventoryBefore`, `plist`, `signature`, `mainPin`, and `inventoryAfter` in the existing candidate build. No paths, credentials, page content or identity material are logged. Validation order, complete content comparisons, strict signature checks and deadlines remain. A final deadline check follows diagnostic output as well.
- Candidate build inputs now pass the existing candidate define to C compilation, in addition to Swift. The diagnostic test consumes those real build inputs, so a diagnostic that compiles only in a hand-built probe is not treated as package coverage.

These changes correct a misleading release error and make the next timeout diagnosable. They do **not** establish that the intermittent observe timeout is fixed. Neither the action/frame/generation budgets nor the resource collector cap was extended, and no validation was cached or skipped.

## Focused verification and main-agent review

Evidence directory: `.build/observe-reply-20261116/`.

- `release-red-final.log`: real Manager orchestration test failed on both closing and closed release replies before the correction. Earlier setup failures lacking the explicit existing routing-test seam are retained separately and are not the behavioral RED.
- `release-candidate-final.log`: one focused XCTest passed. It also checks that genuine in-flight work remains busy, the original close is shared exactly once, and no extra request reaches the failed endpoint. The endpoint is a controlled orchestration fake; this is not signed-browser release acceptance.
- `bundle-trace-red-final.log`: real signed fixture passed its original validation results but lacked stage diagnostics. The fixture resides in a private temporary HOME directory because the external workspace volume has a group-writable ancestor; the original refused attempt is retained, and no ancestor permissions were changed.
- `bundle-build-flag-red.log`: the diagnostic test then failed using actual package C flags, revealing that the Swift-only candidate define did not reach C. `bundle-build-flag-green.log` passes after correcting those build inputs.
- The signed fixture exercises valid signature, wrong identifier rejection, expired deadline rejection, changed contents rejection, fixed diagnostic stages and path redaction. Only its own temporary bundle is mutated and removed.
- Read-only probes of the installed original app: 12 revalidations passed in each diagnostic pass, approximately 0.11–0.14 s each. `probe-with-stages.stderr` records the new stage timings. This does not reproduce the historical 3-second expiration or identify its slow substep.
- Main agent reviewed the production/test/build diffs. No subagent performed review. `git diff --check` passed. No full regression suite was run. Existing Swift concurrency warnings remain in unchanged code.

Commands:

```sh
python3 scripts/test-bundle-revalidation-trace.py
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  -Xcc -DSAFARIER_BOUND_LOCAL_CANDIDATE \
  -Xswiftc -DSAFARIER_BOUND_LOCAL_CANDIDATE \
  -Xswiftc -DSAFARIER_INTERNAL_TEST_APP \
  -Xswiftc -DSAFARIER_MANAGER_ROUTING_TESTS \
  --filter AutomationManagerTests/testReleaseAfterObserveFailureReportsExpiredDuringAndAfterClose
git diff --check
```

## Packaging and runtime verification

The testing release diagnostic candidate was built and installed at `/Users/yingzhang/Applications/Safarier AI.app`, with the fixed copy at `dist/releases/Safarier AI.app` and sidecar `dist/releases/observe-diagnostic-testing-20261116-165439`. Build attempt: `attempt-20261116-165342-94f5afc16e8a47fca0c773bc2586f9eb`. Independent review confirmed all 150 source entries, all 12 pins, strict signatures/namespace/resources and the presence of the C diagnostic label in the packaged executable. DSH remains on the reviewed 0.2.2-rc.2 artifact; no dependency upgrade was added in this change.

Backups: installed app `/Users/yingzhang/Applications/.safarier-install-backup-b35dab8d4d3b49058fcbb522dc8d84b3.noindex/previous.app`; fixed release `dist/releases/.unified-release-backup-bab2ac10e67f4c3d92c27d6f08d0558b.noindex/previous`.

Before normal application quit, this run backed up all existing profile/subscription files, 13 bookmark files, 3 credential files and saved sessions; post-quit backups were also taken. The same two originally running browsers and all three original daemon runtime paths were restored, including the daemon from the historical failed run. Stale sockets were removed only after proving the original daemon PID absent, connection refused, same socket inode/owner and a private owned directory. Old daemon termination for installation is not release proof. DSH's existing service pane was reopened through semantic AXPress. No profile was created or deleted, and 本地inboard remained inactive as it was before this restart.

`metadata-preservation.json` confirms current profile/subscription/bookmark/credential files match the before-quit bytes. `session-preservation.json` confirms original saved URL lists and selections match for all three profiles (My 6, 新媒体运营 1, 本地inboard 1). These claims apply to files present at the start of **this** restart and do not resolve the earlier recovery incident documented in `2026-11-16-registered-generation-ack.md`.

First installed live check reused 新媒体运营 and its existing Google result page. Connect `0E02CB7F-C178-4C6E-9EE4-73983846921F` succeeded in 14.603 s; observe `05D787C8-1B2A-4509-AD8D-46E79F3F16C2` succeeded in 4.412 s. Main visually checked the saved current-page screenshot. Release `14D0FD7C-9257-45D7-A33D-9A6472820EE6` succeeded in 6.867 s, with all four of `inputReleased`, `artifactsCleaned`, `browserRetained`, `manualInteractionEnabled` true. Its own test daemon stopped normally. No navigation or search command was sent. Actual Runner logs contain the new C stage records.

A second focused check held a fresh connection idle for 35 seconds before observe/release, approximating the historical sequence duration without replaying navigation. Connect succeeded in 19.009 s, observe `DA58F524-F660-45A3-B19B-8C47069C9CCB` in 4.468 s, release `098E0CC8-0349-41DB-BA72-01AE799A45A9` in 6.880 s, again with all four release fields true; its test daemon stopped normally. Total time including the deliberate idle was approximately 66.25 s. The screenshot again shows the existing result page. This diagnostic candidate has not yet reproduced the historical expiration; successful checks alone do not establish its resolution. Changes remain uncommitted and unpushed.
