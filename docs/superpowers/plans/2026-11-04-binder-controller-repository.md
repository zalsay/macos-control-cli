# Binder Controller Repository Lifetime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Main agent alone performs design/code review; no delegated reviews. This is a future plan, not authorization to execute.

**Goal:** Bind the actual controller client's startup, queued sends and reply commit to one retained repository baseline and actual owned child/peer.

**Architecture:** After human approval, adapt the existing 017 bound write queue and actual `AutomationRunnerClient` using a concrete bootstrap-to-client context and one transferred reader lease. Preserve original runner behavior and client correlation; no parallel client or transport.

**Tech Stack:** Swift, the existing Foundation/POSIX offline CLI fixture and BinderIdentity bridge; ASan only when separately authorized. No XCTest or whole-Core build alternative.

**Spec:** `docs/superpowers/specs/2026-11-04-binder-controller-repository-design.md`

## Global Constraints

- DRAFT: human approval of the exact architecture and main-agent design review precede *all* source/test implementation.
- No code review delegated; preserve unrelated dirty work and all existing frozen artifacts.
- Existing `.controller` provider: whole-document baseline before launch; no ProfileLock acquisition, no PID-file ownership assertion. Runner holds its original lock.
- Reuse original kernel bridge, owned child birth/actual peer, original launch spec/args/environment, existing 017 queue/physical write, real client state and one reader lease.
- Exact caller cutoff never renewed or silently shortened to a default 3-second frame; apply the explicitly documented independent 45-second offline fixture outer lifetime. Preserve original attempted transition and side-effect semantics; no stale/late commit.
- No new transport, collector, verifier callback/protocol/Boolean, permissive workspace, nil-role fallback or generic pre-peer escape.
- Fixture only; `productionComposition` unavailable and all gates listed in spec false; no GUI/TCC/LA/LS, real profile, process scan or unapproved cleanup.
- Existing 017 fixture directly uses `FoundationProcessSpawner().spawnOwned(...)` with `spec.arguments()`, `environment: env`, and `standardInput: pair.child`; retain its `OwnedRunnerProcess`. `RunnerLauncher` is production reference only, never run or stubbed in this fixture.
- A build failure, missing API or compile-negative is structural evidence only, never behavioral RED. Runtime RED requires an observed target-oracle violation in a compiling original actual path or future approved isolated copy. Scheduling hooks control interleaving only and never fabricate authorization results. If no legal behavioral RED exists, record it unverifiable; do not bypass the constraint.
- Historical 112 calls/2998 entries are not present-run verification. No commit, push, install or release unless separately authorized.

---

### Task 0: Stop for architecture approval

**Files:** Read the spec and actual baseline; modify none.

- [ ] Main agent confirms the specification incorporates all 12 rulings and performs its own design review. The recommended exact attempted transition remains the original sent-ID insertion and `attempted = true` before `channel.send`; the closed role constructors, both concrete owner factories and `ControllerGenerationContext` reside in fixture-derived `AutomationRunnerServer.swift`, using `fileprivate` initializers without widening access. Any newly discovered contradiction requires a revised design and renewed human approval.
- [ ] Obtain explicit human approval of that exact revised design. If approval is absent or source feasibility contradicts it, stop. Reconfirm ownership of the future test directory and execution/environment authorization before any test/build/ASan; this document does not grant those permissions.

### Task 1: Controller baseline, ownership and bootstrap seam

**Future files:** 017-derived `V1KernelFixture.swift`, `RepositoryBindingProvider.swift`, `KernelIdentityBridge.swift`, `OwnedRunnerProcess.swift`, `AutomationRunnerClient.swift`; test location and executable command must be selected from the existing authorized offline harness after Task 0. Do not modify frozen 017 itself. Deterministically copy the 236-line real client actor into the authorized offline fixture and factor only its workspace/launcher-dependent startup entry; record source hash and exact retained/extracted ranges. Do not load or stub the real workspace or add any production startup stub.

**Interfaces:** consume existing `makeFixture(executablePath:role:expectedSpec:actualArgs:environment:)`, `read(deadline:)`, `ownedChildMetadata`, `checkSelf`, `checkResources`, `checkPeer`. Produce approved concrete `ControllerGenerationContext` before spawn and its attach-once owner/birth operation, then the fixture-copy common bootstrap seam; preserve the original real-client actor core and leave production startup/composition untouched.

- [ ] Write focused failing fixture cases: create the sole context/provider/lease and snapshot the complete document before actual child launch; mutate an unrelated record or replace repository before spawn admission and require no spawn. Mutate during `Process.run` separately: require mismatch/closed, zero request frames, no rebaseline and owned-child cleanup rather than claiming retroactive no-launch. Assert `.controller` never acquires child `ProfileLock`; original args/environment parse to same spec.
- [ ] Run only the approved fixture's focused baseline cases; capture command, failure and baseline hashes. A runtime RED is only a recorded target-oracle violation on a compiling original path or approved isolated copy. Absence of a retained provider/API or inability to compile is structural evidence, not runtime RED. If the oracle cannot be legally exercised, record behavioral RED unverifiable; if a case passes, establish whether it actually exercises this boundary.
- [ ] Implement the approved fixture-copy context before launch, retaining the same provider/baseline, bridge, channel, inspector and claimed lease. Reuse `FoundationProcessSpawner().spawnOwned(...)` with the 017 fixture spec arguments, environment and child input, and attach its original `OwnedRunnerProcess` and birth once after spawn; do not run or stub `RunnerLauncher`; leave production workspace entry untouched and never substitute a permissive workspace.
- [ ] Rerun the exact focused cases: expect PASS, plus unchanged baseline C snapshot. Record evidence separately from historical runs.

### Task 2: Closed binding, one hello and reader transfer

**Future files:** 017-derived `AutomationRunnerServer.swift`, `AutomationChannel.swift`, fixture copies of `AutomationHandshake.swift` and `AutomationRunnerClient.swift`, and corresponding offline CLI fixture cases. The concrete context is in the fixture-derived `AutomationRunnerServer.swift`, not a separate file.

**Interfaces:** fixture-derived `AutomationRunnerServer.swift` houses both concrete owners/factories and `fileprivate` binding/admission initializers; closed owner enum and privately minted `controllerHello`/`controllerRequest` admissions; `negotiateBound(context:startupCutoff:)` uses original codec and exact `AutomationChannel.ReaderLease` passed once to actual client's read loop.

- [ ] Write failing tests for one original hello before peer pin; reject second hello, request before ready, malformed/mismatched ready, actual peer mismatch, different channel/lease/generation, expired or missing owner, and reuse of consumed bootstrap. Prove there is one reader and that public receive/send cannot bypass a bound channel. Verify stale/foreign capability closes rather than falling back.
- [ ] Record that the current server-only `FixtureWriterBinding` cannot mint controller admissions and original handshake uses public receive as structural source/API evidence only. Run a legal behavioral oracle only on a compiling original path or approved isolated copy; record the observed violation as runtime RED, or record behavioral RED unverifiable if that oracle cannot be exercised. Do not invent a role or fake validation outcomes to produce RED.
- [ ] Implement the approved closed concrete role and lexical mint in fixture-derived `AutomationRunnerServer.swift`: retain `fileprivate` constructors there and add `ControllerGenerationContext` and its concrete owner factory in that same file, without generic callback/protocol/Boolean or widened initializer access. Install before hello, queue/validate hello against baseline+self/resources+fresh owned child, then parse ready, pin actual peer, repeat checks, construct the actual copied client with ready runnerInstanceID and attach that client once to the same context, transferring the lease once. Context weakly references the client and the client strongly retains context. Preserve existing server kinds and queue identity checks.
- [ ] Rerun tests for PASS. Explicitly exercise owner release and context failure during handoff; verify no reader overlap and no request frame before ready+pin.

### Task 3: Outbound head/retry, cutoff and cancellation

**Future files:** 017-derived `AutomationChannel.swift`, binding/context, actual `AutomationRunnerClient.swift`; fixture scheduling tests.

**Interfaces:** `validateQueuedWrite(_:)` dispatches only to the concrete owner; pending `(requestID,generation)` and original absolute cutoff flow to single-claim admissions; 017 write-queue receipt and one physical writer remain authoritative.

- [ ] Write failing cases that suspend the actual request at queue head and between a partial write/EINTR retry; mutate actual C repository while queued, assert zero next physical write and no stale success. Also test binding replacement/foreign admission, validator completion after job removal, and unchanged repository happy path. Attribute denial to the controller queue validation itself; zero bytes caused by runner rejection are not proof. Foreign receiver closes only itself without consuming or revoking the original foreign owner.
- [ ] Write race cases around the original actor transition: before `sentIDs.insert` and `pending[id].attempted = true`, cancellation/timeout finishes only that request and leaves unrelated work alive; after that transition, including channel-queue waiting and partial write, cancellation/timeout closes the connection and mutating actions report possible side effects. Original `sendBackpressure` alone retains its explicit definitely-unsent `sessionBusy` handling and sent-ID reversal. Exercise ordinary/control reservations and 4096 tombstone ceiling without replay.
- [ ] Add a focused controller reservation test with a full byte budget: valid matching live ownership and one claimed admission, `reserveBound` returns `sendBackpressure` before enqueue/write, admission settles once, no budget leak, client removes the sent ID only when the same generation is pending and returns `sessionBusy` definitely-unsent, and a later independent request succeeds on the same healthy generation. Exercise the cancellation/timeout race so the original pending-generation guard prevents double completion or out-of-turn tombstone changes.
- [ ] Add contrasting reservation tests: runner backpressure still closes exactly as 017; controller closed/identity/foreign/duplicate claim errors terminate the receiver, and a foreign admission does not consume or revoke its original owner. Confirm the same single writer and no enqueue/write on rejected controller reservation.
- [ ] Before the role split, run the targeted reservation behavioral oracle only if a legal compiling original path or approved isolated copy can exercise it; capture an actual healthy-generation violation as runtime RED. The source fact that 017 `sendBound` closes on all `reserveBound` failures, or missing controller role/API, is structural evidence alone. Otherwise record runtime RED unverifiable without faking authorization or bypassing constraints. Implement the explicit role split in the existing `sendBound`: after valid ownership/claim, only controller `sendBackpressure` before enqueue/write settles that admission and returns the original error without closing a live generation; all terminal races/errors and runner reservation failures retain their role-specific terminal behavior. Keep the original client's generation-guarded catch unchanged and preserve the original attempted transition before `await channel.send`.
- [ ] Run focused cases only where the original path or approved isolated copy compiles and the target-oracle violation is observable; save bounded timing/byte-count evidence for actual runtime RED, or record it unverifiable. Compile failures do not count as RED. Implement the original actor attempted/send transition and queue revalidation at head and each retry, without arming runner-wide timer while controller work remains unattempted. Controller check cutoff is `min(original caller deadline, original offline 45-second lifetime expiry)`; startup uses its own captured cutoff instead. Use an owner-derived sealed fixed-expiry extension if needed and retain runner 017 3-second/45-second defaults and bridge/C duration conversion. Never silently apply the 3-second runner frame limit to controller caller timeout or restart any deadline.
- [ ] Rerun focused cases for PASS; demonstrate one physical write path and no next-byte commit following failed validation. Preserve original runner queue timer and 017 regression behavior.

### Task 4: Inbound verification and late reply guard

**Future files:** actual `AutomationRunnerClient.swift`, concrete controller context, fixture scheduling tests.

**Interfaces:** use original pending record and generation/cancellation flags; full context check is awaited between initial and final actor-isolated guards, before the existing continuation commit.

- [ ] Write a controller-isolated failing test: first let runner checks succeed, emit a valid reply and become idle; pause the controller after reading/correlating but before controller context check/commit, mutate actual C shared repository and require controller rejection rather than success. Separately test mutation during the full check; cancel or timeout while check suspended; replace pending generation; deliver late/unknown/foreign reply or mismatched target. Assert no continuation success, no double resume, correct original connection/error/side-effect mapping, and no use after context release.
- [ ] Run the target oracle on a legal compiling original path or approved isolated copy and capture an actual runtime RED, or record behavioral RED unverifiable; compile failures or simulated validator results do not count. Implement minimal real-client receive-path checks before and after each await and immediately before continuation resume; relookup the same live Pending generation/action/cancellation/deadline each time instead of retaining a stale Pending value. Do not add a separate client, result cache, or collector.
- [ ] Rerun for PASS; use scheduling barriers to exercise each interleaving, including close during suspended verification and old-generation completion after new context starts.

### Task 5: Regressions, cleanup and evidence

**Future files:** authorized fixture tests and execution evidence only; no production composition wiring.

- [ ] Write/execute cleanup cases for running owner + matching fresh original birth, mismatched/unavailable birth, already-exited child and unconfirmed wait; assert no scan, PID-file inference or wire kill. Hold validator while synchronously revoking the single first-terminal record and channel, ensuring each pending continuation finishes at most once and descriptors remain valid until checks drain or are excluded. A cancelled caller uses detached owner-only cleanup after natural wait; record `cleanup_unconfirmed` when identity or exit is not confirmed.
- [ ] Run the full authorized 017 runner regressions including original ready/response/diagnostic head/retry and historical mutation scenarios, then actual-C launch/queue/reply mutation matrix and cancellation/late/foreign cases; record exact commands, exit status and outputs. Test caller deadlines shorter and longer than 3 seconds without silent frame-cap shortening, and the independent 45-second offline lifetime limit. An ASan run is a separate explicit future permission and gate, not a substitute for the matrix; run it only when authorized, and report unsupported/inconclusive separately.
- [ ] Main agent alone reviews source changes and evidence. Report changed paths, test command/results, remaining races and unmet gates. Do not call historical counts new tests; do not mark production, GUI or permission gates ready; do not commit or deploy.
