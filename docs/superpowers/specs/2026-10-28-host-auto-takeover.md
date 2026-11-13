# Host automatic soft-pause takeover (approved)

User-approved boundary: Host automatically takes over initially and on a fresh input after mouse activity or ordinary focus loss, without clicking Continue; retain the original displayed three-second countdown. Explicit Pause/Cancel/Close, transport uncertainty/loss and crash recovery remain stopped. Local non-Host behavior stays manual.

## Existing path and minimal changes

Reuse Host -> owner-checked Unix daemon -> Service -> the one native InputCancellation lease/epoch executor. Do not add an executor, simulate the Continue button, clear runtime/state, replace a connection, add OCR verification, or retry a failed input.

1. InputCancellation records `pauseReason`: `none`, `userInteraction`, `focusLoss`, `manual`, `transport`. Explicit manual/transport reasons escalate an existing soft pause and cannot be downgraded by later soft events. Existing `pauseExecution(lease:)` remains explicit manual. Add `pauseForFocusLoss(lease:)` for ordinary focus/anchor loss; pointer/activation monitor continues using user-interaction pause.
2. Native transport state adds `hostAutoTakeoverVersion: 1` and `pauseReason`. Add only an internal owner-mediated `transport-auto-resume` action requiring `expectedLease` and `expectedInputEpoch`. It atomically requires the same live lease/epoch, a soft reason, phase paused, no transport lock and no counter overflow. On success advance epoch exactly once, preserve lease, set phase awaitingCountdown and reason none, and return `autoResumed:true` with full transport state. Do not start a timer here: the original target/window checks and actual toast display start the original three seconds. Old/queued permits stay invalid.
3. Daemon auto-resume exists only on remote reservation, after owner/peer/liveness/sequence checks and before reserving a *new* input operation. The reservation carries only sanitized connection/frame intent, not text/key/model credentials. Service verifies the existing connection, release state and registered frame in memory; native original action gates still verify exact target identity, geometry, focus and permissions before any input. Non-input actions never auto-resume.
4. Track whether daemon recovery came solely from a proven soft pause. Unknown state, malformed/missing capability, state/ACK timeout, owner death, explicit manual or transport pause must not become auto-eligible. Hard recovery wins. Auto-resume ACK must prove identical lease, expected epoch+1, no lock/pause and awaitingCountdown; otherwise fail closed and do not dispatch. Local APIs and public WSS requests cannot supply internal takeover fields or invoke the native transport action.
5. Initial execution is already automatic and remains unchanged. Host SessionManager network LostPaused/RecoveryRequired flows remain unchanged: no automatic transport recovery and no repeated requests.

## Validation

Native fake-clock tests: initial/no-timer-until-toast behavior, soft pointer/focus auto resume, same lease/epoch advancement, old permits rejected, manual-after-soft and transport-after-soft escalation, wrong lease/epoch, overflow, cancel/no lease, unchanged local manual resume, strict native request decoding. No real system input in native BDD.

Rust tests: new request with same owner/connection/frame succeeds after proven soft pause; explicit/manual/transport/unknown/uncertain states stay blocked; stale sequence/wrong owner/bad frame/non-input action cannot resume; no replay of old input, no extra helper/claim/lease. E2E loopback real Host/client with controlled fake Native simulates soft then manual pause and checks one actual fake input per fresh request.

Release candidate version 0.3.6; preserve installed local 0.3.5+1, remote 0.3.5, credentials/config, old packages and tags. Do not commit/push/install/deploy until separately requested. Main agent alone performs code review; worker implementation is allowed.

Host and remote client pause errors retain the original FOCUS_LOST/USER_PAUSED schema but use a fixed, redacted message distinguishing soft takeover from hard stops. Local error copy is unchanged; the receipt cache only retains the two known fixed pause strings.
