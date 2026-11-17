# MCC and Host JSON scripts

User approved multi-step execution with JSON instead of command lines.

## Contract

`mcc script --connection ID --file /absolute/flow.json [--frame ID]` and the same command behind the existing `--remote` prefix. JSON is `{ "version":1, "steps":[...] }`, optionally `timeoutMs` (1–40000, default 40000). Each step uses existing action fields. Support observe, click, click-target, type, press, scroll, existing desktop move/hover/drag/actions, plus wait with ms (0–10000). Steps inherit one connection and latest frame; peer steps cannot change connection/frame, run management commands, nest scripts, or supply model credentials. `eb:true` means per-step --eb; omission/false uses the original backend.

One file <=32KiB, 1–64 steps, total explicit waits <=10000ms. Validate the entire schema and statically knowable input fields before any input. Dynamic geometry/focus and BLE preflight remain in existing executors. Inputs requiring a frame must follow observe/click-target or receive outer --frame. Observations during a script remain on Host; only frame IDs and bounded execution summaries are returned, not screenshot bytes or OCR/text contents.

## Execution

CLI loads JSON, never a shell. Remote CLI inlines the script in one authenticated request. Service retains its lock and original connection while invoking existing observe/input/click-target paths. Existing execution preprocessing resolves the Host's model once if needed. Each step checks cancellation, native pause/recovery/epoch and a shared deadline. Native requests honor the remaining script deadline without changing ordinary request deadlines. Native helper timeout keeps its existing conservative teardown/recovery behavior; an accepted BLE packet may remain uncertain. Waiting is interruptible and never resumes paused input. Script completion means dispatched operations, not verified UI effects. No rollback/replay/resume of partially completed scripts.

## Receipts and protocol

Success returns connectionId, optional latest frameId, totalSteps, completedSteps and bounded per-step summaries. Failure preserves its original error code and includes progress plus 1-based failedStep in error.receipt. Preserve existing nested native delivery uncertainty receipts. Host advertises `remote.script.v1`; older Hosts reject before execution. Session ownership/frame authorization, heartbeat and single-flight checks apply to the whole script. Register the last script-produced frame on success or failure for subsequent authorized input; cache projection strips arbitrary payloads and replay returns receipts without rerunning steps.

## Validation / scope

Only parser/schema, script Service execution, real WSS/fake native tests, native deadline and existing touched gate/receipt tests. Build macOS package without installing. No full regression, hardware acceptance claim, Git push, release or deployment. Main agent reviews. Preserve dirty source checkout; use isolated branch based on merged main.
