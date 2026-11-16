# Read-only authorization query stall

Baseline: `b690c60` on `mcc-safarier`, preserving the existing uncommitted
takeover, DSH and external ACP corrections.

## Evidence and scope

A read-only `sfa authorize` issued from the current Codex host produced no output.
Sampling the owned CLI process showed the worker blocked inside
`AEDeterminePermissionToAutomateTarget`, reached through
`cs_control_authorization`. The CLI main thread continued its normal run loop.
Only that owned query was terminated. A separate Manager sample showed its main
thread waiting in the AppKit event loop. The collected TCC log had no diagnostic
events explaining why the system permission API stalled.

This identifies the blocking boundary and the missing application-side waiting
limit. It does not establish the internal macOS/TCC cause, or establish that
Codex and DSH share authorization. No consent request or TCC reset was issued.

## Change and focused validation

Updated the existing `ControlAuthorization.perform` path: default read-only
permission queries wait at most five seconds after the initial identity check.
A stalled query returns `unavailable`, `osStatus:-1712`, exit 1 and
`businessEventSent:false`. Main-actor isolation makes completion exactly once;
late native results cannot change the timeout response. The underlying system
API cannot be cancelled. No retry or consent prompt is added. Timely results
retain the original target checks. Explicit `--request` retains its human wait.
The deadline does not cover the separate initial Manager identity captures.

The new regression test failed before implementation: the query waited for a
6.5-second native seam and incorrectly returned `allowed` after the intended
budget. All nine `ControlAuthorizationTests` passed after the fix, including
late completion, explicit consent beyond five seconds, status mapping and target
change checks for both modes. Only this test class ran, with the testing App
compile flags; no full regression suite ran. The main agent reviewed the source
and concurrency paths. Existing unrelated AppKit warnings remain.

## Local package and runtime acceptance

The testing release build completed using the existing candidate builder. The
existing packaging, signature, pin, staging and installation helpers assembled
and installed the package. All 150 inventoried source entries matched the build;
all 12 pins and the fixed/installed App checks passed. DSH remains the existing
0.2.2-rc.2 runtime image; no runtime or external ACP plugin changes were made for
this correction.

The two browser helpers and Manager accepted normal quit requests. Session files
were backed up before and after quitting. The old daemon's normal stop returned
`SESSION_BUSY`; after Manager, browsers and DSH exited, that exact daemon was
terminated. This is not a control release acknowledgement. Its stale socket was
removed only after confirming connection refusal, owner/mode and unchanged inode;
an idle daemon was then restored on the same runtime directory.

The installed Manager, both original environments and DSH were restarted.
My retained six tabs and the disabled Agent setting; 新媒体运营 retained one tab
and its existing Agent setting. Profile configuration was unchanged. The
registered environment's saved tab content matched; My restored the same tab
count, with page title updates and one localhost path change during reload.
No search or new task tab was submitted, and no takeover connection was attempted.

The installed `sfa authorize` returned `allowed`, exit 0, in **0.247 seconds**
from the current **Codex host process chain**, with `businessEventSent:false`.
This run exercised the normal real-system result, while the focused regression
test exercised the five-second timeout. DSH-host authorization still needs its
own read-only retest. The earlier takeover/hello EOF issue is not declared fixed.

Private evidence, session snapshots and recovery paths are under
`.build/authorize-timeout-20261116/`, including `installed-review.json`, test logs,
stack samples, package logs and the installed CLI result. Build attempt:
`attempt-20261116-144334-5e1d9ad099d346f8ad34385368cd99de`.
Changes remain uncommitted.
