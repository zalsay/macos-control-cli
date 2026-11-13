# Retained v1 fixture context offline — implementation plan and staged status

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` or `superpowers:executing-plans` for task-by-task execution. The user override reserves all code and design review to the main agent; workers do not conduct or delegate reviews.

**Goal:** Build one server/channel-generation-bound runner fixture context joining the original v1 single reader, actual C identity and the private fixture provider with its original lock, with sticky fail-closed checks.

**Architecture:** Extend the existing staged v1 server and original request/write pipeline with one privately installed, retained concrete runner fixture context bound to its actual channel and seam lifecycle. Reuse the original v1 wire protocol and reader; add no transport, second reader or production composition API. Server presend checking does not supply full context revalidation at the actual serial channel writeQueue dequeue/system write; that remains a production blocker.

**Tech Stack:** Swift Foundation and Darwin, original C collectors with Security and CoreFoundation, and focused CLI fixtures in normal and ASan configurations.

**Spec:** `docs/superpowers/specs/2026-11-04-binder-v1-context-offline-design.md`

**Status:** Unit 1 was adjudicated; bounded fixture implementation and worker runtime were subsequently authorized. The current candidate is worker attempt 014, not production Sources. Main alone conducts code/design review, and its final-014 independent mechanics, signed-fixture and setup matrices passed; final audit and closure remain in progress. The separately precreated HOME700 receipt authorizes only the designated workerOwned fixture namespace; it does not authorize real profiles or production promotion.

## Preconditions and exact write boundary

- Re-read contract and current state; never overwrite others' concurrent work. No edits to Sources, Tests, scripts, prior attempts, main files or production APIs. Staging only in newly numbered directories under `.build/automation-binder-v1-context-20261104/worker/`, using copied frozen files; append-only attempts, failed command/log/source SHA recorded. Verification documentation is separately authorized for the current synchronization.
- No process scans, deletes, manual `/tmp`, `/var/folders`, tempfile or worker-created HOME roots, refusal workarounds, GUI/AppKit/WebKit, AppleEvents, TCC/LA/Keychain/LS/open/VM/App, real profiles, install/release/commit/push. `TMPDIR` is contract worker tmp and caches contract worker cache. Build fixtures before pinned sessions; no top-level HOME mutation during sessions. No full Swift test/Core/App build.
- Reconfirm exact frozen paths listed in spec and `makeFixture` fixture path/args requirements; don't substitute models or synthetic collector. Main independently prepares baseline/oracles. Full gates remain false.

## Task 1 — explicit generation binding and lifecycle (staged; validation partial)

1. Copy attempt-019 server/channel and required seam support; copy attempt-026 actual C bridge/bundle sources and attempt-002 provider plus attempt-040 model/lock dependencies to fresh attempt. Record hashes and exact copy/build inputs. Resolve any incompatible duplicate declarations in fixture staging only, without modifying frozen originals.
2. Introduce fixture-internal retained context attached by server after verifying same `AutomationChannel` object and actual server-owned one-shot seam/phase. Private installation must not accept caller-chosen UUID as authority. Keep `ReaderLease` as sole reader, inspector strictly nonreading. Deny cross-server/channel handoff, double installation/consumption and post-close reuse.
3. Create runner provider through actual `makeFixture` using bridge-verified executable, real actual args/environment and expected spec; take first baseline read and retain provider/original lock. No controller lock-ownership assertion, no lock replacement or reacquisition.
4. Serialize bridge/provider operations with lifecycle and release; define closed transition, cancel, owned resource release and late-result fence. Explicitly handle active noncooperative callbacks without fd reuse/use-after-close. Confirm controller termination uses only retained owned process plus fresh original metadata, with unconfirmed cleanup represented.

**RED then green focused cases:** wrong channel object with plausible UUID; foreign server handoff; stale generation; double consume; close while operation pending; same-provider baseline change; original lock replacement/loss; repeated close; absence of a second read admission. Red tests must fail for the intended condition, not merely fail to compile. Log commands, source SHA, exit, asserted phase and negative-test-success distinctly.

## Task 2 — checks at actual boundaries (staged; actual channel dequeue validation missing)

1. Integrate throwing context checks into copied server before/after hello receive, ready send, handoff preparation, request receive/admission, unavailable-handler invocation/return, response enqueue/dequeue, write await completion, and malformed diagnostics. Recheck server phase/generation after every `await` and before commits; don't use an externally supplied boolean auth predicate. Retain original v1 codec and no extra wire bytes.
2. Each check uses real retained bridge `checkSelf`, `checkResources`, `checkActualParent`, `checkPeer` on same inspector, `checkActualParent` again, and same provider `read` with C monotonic deadline derived from unrenewed budget. Recheck cancellation/deadline/state after synchronous calls. Fail closed; close channel, fence late completions and queued writes. Preserve original serve path unaffected.
3. Ensure handler is fixture-only unavailable and side-effect-free; counts distinguish attempted admission from an actual handler entry and response commit. Ensure no write after observed closed admission; document partial write/TOCTOU and noncooperative limitations rather than claiming atomicity.

**RED then green cases:** parent/peer/self/resource mismatch, repository bytes/inode/mode/model change, lock descriptor/path mismatch, expiry before and after C/repository calls; peer EOF at each await; cancellation around preparation/handler/write; timeout followed by late completion; blocked writer and partially sent frame; invalid frame diagnostic; handler not entered / response not committed after invalidation; stable valid unavailable request follows original v1 frame sequence. Assertions must separately count ready bytes already sent, admission, handler, response and shutdown; expected deny is not a business success. Include prior staged legacy baseline compatibility checks.

## Task 3 — bounded actual-C fixture evidence (independent final-014 matrix passed; broader gates deferred)

1. Prepare fixture binaries before any pinned session with per-command `TMPDIR`/cache paths from contract and no top-level HOME changes during session. Use main-authorized precreated HOME700 only, generated fixture-only profile data and copied actual support. No manual temporary roots. Reject unexpected `DYLD_` as existing fixture does.
2. Run targeted normal and selected negative actual-C tests against retained exact server/channel/provider, not a synthetic callback; validate original held lock in runner and controller independently validates only owned child/peer facts. Record fixture output, exact command, source SHA, observed exit and bounded cleanup; stop on unconfirmed ownership/cleanup. Main independently runs its own oracles.
3. Assert one server generation, same retained provider and lock throughout; mutate only authorized fixture data in controlled checkpoint tests, restore solely through explicitly allowed fresh attempts (no deletion). Exercise canceled/noncooperative work and distinguish logical fencing from actual termination. Validate full gates false, unavailable handler and unchanged legacy behavior. Do not claim GUI/production security, race elimination or complete leak freedom.

## Task 4 — handoff

Report changed staged paths, exact tests and results, failures, deviations and limits to main. Main alone determines design/code review and acceptance. Do not claim full integration, promotion, real-app behavior or readiness. Preserve unresolved prior process-scan and temporary-glob deviations regardless of test outcomes.

## Main adjudication (2026-11-04)

Follow `main-review/design-adjudication.md`, `independent-oracles.md` and `fixture-root-authorization.json`. Unit 2 is approved, but only the runner retains the concrete context; controller independently checks original owned child/peer and lock observations without claiming child lock ownership or its own persistent repository snapshot. Pre-hello intentionally does not assert peer last-use. Immediately revoke the owned channel on terminal failure; serialize cleanup and report unconfirmed noncooperative work honestly. Begin with genuine old-v1 runtime behavioral RED, separately classifying source-interface and compiler failures; retain exact logs and source hashes. Sign all case namespaces before starting pinned runtime. No production promotion.


## Execution and verification status — worker evidence only

- **Staged, worker subset observed:** attempt 013 installs the retained runner context, uses the original seam, actual C bridge and original `makeFixture` provider/lock. Worker normal signed fixture completed two unavailable requests; a repository mutation between requests produced a typed `repositoryChanged` denial observed at the prior write's post-send check, with one handler invocation and no second response. Worker also ran the two foreign-token mechanics corrections, DYLD rejection and an owned-child error cleanup case. Exact artifacts and limitations: `docs/verification/2026-11-04-binder-v1-context-offline.md`.
- **Deferred / not verified by this worker:** wrong-channel/stale-generation bound-context misuse, complete peer/self/resource/repository/lock mutation matrix, old-inode release vs replacement, all cancellation/EOF/handler/write interleavings, noncooperative cleanup/TERM branch, full malformed-frame paths, and attempt-014 ASan. Do not infer completion from earlier attempt-011 legacy tests. Main's final-014 independent matrix results are recorded below; final audit and closure remain main-only. Remaining requirements in this bullet are not all established by that matrix.
- **Unimplemented production blocker:** the worker presend check occurs before submitting to the existing serial channel writeQueue. There is no full identity/repository validation at actual queue dequeue/system write. The queue can wait after validation and post-send failure can occur after bytes were exposed. No new write engine, collector or synchronous bridge workaround is authorized by this document. A separate design/authorization is required before solving or claiming this boundary.
- **Discipline:** main-authorized HOME700 root was precreated; worker uses only its workerOwned namespace. Attempts 002–008 used task-root tmp/cache rather than worker/tmp and worker/cache; see the verification record. Do not clear that deviation or the prior temporary-glob and process-scan incidents. No production promotion, GUI, real profile or gate enablement follows.


## Attempt 014 targeted correction status

Main found an actual-C handler-after repository denial incorrectly reported as status 0 in attempt 013. Worker corrected bound EOF/loop exit status and terminal install failure handling in immutable attempt 014; it reused the unchanged main actual-C harness for normal, handler-race, clean EOF and cancel-handler focused runs, plus wrong-profile/closed-inspector tests and selected original mechanics. These results are worker-run subset evidence, not by itself main's final-014 independent matrix or final audit. The actual serial writeQueue dequeue/system-write validation remains unimplemented and is not authorized by this correction.


## Main final-014 verification and remaining acceptance boundaries

Main's three fresh, final-source summaries record **74 top-level CLI calls**, not 74 distinct cases: `main-review/final014-mechanics-summary.json` 30 (24 seam + 6 legacy, normal/ASan), `main-review/bound-independent-014/summary.json` 34 (32 signed actual-C bound calls including normal repeats + 2 expected-exit-1 DYLD refusals), and `main-review/context-init-final-014r2/summary.json` 10 (five setup modes normal/ASan). The older baseline 30, setup-005 eight, failed-013 and worker counts are excluded. Assertion-success exits for expected denials do not mean business success.

The main bound matrix covered the stated repository bytes/inode/mode/unselected-record changes, before-ready/before-prep fences, handler-after mutation race, original-held-lock rename/replacement and later original inode unlock, cancellation/EOF late-handler fencing, malformed diagnostic, enabled-outcome refusal and foreign-token recipient closure with legitimate owner continuing. The initial canceled-install oracle correction is preserved in `main-review/context-init-final-014/oracle-correction.json`: only `CancellationError` or `ChannelError.closed`, with cancellation, closed channel and no retained lock, are allowed. The earlier harness compile error from omitted `()` when calling `admittedReadersForTest()` is not a feature RED. `main-review/reuse-014.json` and `main-review/bound-independent-014/image-audit.json` preserve provenance and static symbol-audit evidence.

**Still deferred/not established:** full context validation at actual channel writeQueue dequeue/system write; controller-side retained repository context; atomic OS peer/filesystem/write guarantees; all possible noncooperative cleanup, TERM/unconfirmed branches and all races; real app/GUI/input, consent, shipping or production composition. The queue gap is a production blocker, not merely a theoretical final-instruction race. Main alone determines final audit and closure. All gates remain false and no promotion is implied.
