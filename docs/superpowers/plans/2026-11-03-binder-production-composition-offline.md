# Binder production composition — checkbox plan

Status: main-agent independent review accepted the bounded offline work in `.build/automation-binder-composition-20261103/main-code-review.json`. This is not a production-ready Binder or positive product integration; product-source promotion and the future context API are not approved. Main owns final audit at `.build/automation-binder-composition-20261103/main-final-audit.json`.

## Task 1 — design and map
- [x] Read the continuation contract and actual Entry/bootstrap/gates and frozen provider/integration; record boundaries and future lifetime requirements in the design.
- [x] Propose the minimal staged files and APIs and obtain independent main design review and bounded implementation assignment.

## Task 2 — fixture naming (worker implementation; main independent checks)
- [x] Preserve selected freeze 031 source copies in `worker/attempt-002-task2-task3-freeze/original` and hashes before testing; retain old freezes.
- [x] Rename only copied `RepositoryBindingProvider.make` to `makeFixture` and copied test callers; preserve original provider body, C/header, limits, root/spec, ProfileLock and JSONStore observation logic. Main's independent exact comparison passed.
- [x] Compile the normal provider module and typecheck both copied callers. Old `make` compile-negative fails specifically with no such member. Main independently typechecked a positive `makeFixture` call without actually invoking the factory. No HOME or kernel fixture was run by the worker.

## Task 3 — non-authorizing port (worker implementation; main independent checks)
- [x] Add the staged no-argument `ProductionCompositionPort.requireContext() throws -> Never`, a pure throw of `.unavailable`; no returned witness, callback, boolean, fixture selection, product wiring or new shipping gate. It is noncomposable and not the approved future production API.
- [x] Worker normal and ASan tests exercise unavailable rejection with inert opt-in profile/UUID/spec/path/fixture-claim background values. Harness counters are not syscall tracing. Callback and fixture argument injection fail compilation as no-argument calls; test-only in-memory fallback mutant prints its explicit marker and exits 1 while still throwing unavailable.
- [x] Main independently ran port normal/ASan green programs (7 pure refusals each), normal/ASan explicit fallback mutants (expected exit 1), and four compile-negative probes: old `make`, approval callback, fixture claim, and `verified true`. Main independently checked the exact pure-throw body. Counts are not combined with worker runs.

## Task 4 — original unavailable entry (main exclusively)
- [x] Main extracted the original Foundation-only entry enum including comment verbatim and used the original six Core files in socketpair programs. This is not the full App, GUI or kernel Binder execution; worker did not run this task.
- [x] Main ran 8 extracted-entry programs: three normal and one ASan unavailable programs (14 requests each), normal/ASan wrong-profile handshake programs, and normal/ASan missing-session key-frame programs. Main also ran two original-source check scripts, totaling 42 assertions.
- [x] Main retained and separately identified its initial invalid-session cap/open harness attempt; the corrected entry-session attempt uses original v1 semantics. The initial `invalidRequest` is a harness error, not a product failure or feature RED.

## Blocking future transport seam — separate authorization required
- [ ] Before positive wiring, obtain review of a wire-compatible v1 single-reader authentication seam and ownership transfer of any consumed handshake state. Staged `ControlEnvelope` is not product v1 `hello/ready` plus `AutomationRequest`; no double handshake/reader, private v1 prelude or nonce/PID-as-kernel-proof.
- [ ] Resolve current App ordering: `prepareBackground` / `makeAutomationService` precede server's hello read; true binding must precede backend/GUI preparation. Carry and revalidate the same generation-bound context and original held lock through entry, preparation, service and owned page, including invalidation and owned cleanup. None of this seam/context is implemented here.
- [ ] Preserve existing factory/native/service/shipping gates and default v1 unavailable behavior; separate human/GUI evidence and authorization are needed for any actual GUI/input enablement.

## Audit and safety
- [x] Main's direct-symbol audit of the two normal images found no direct GUI/input/permission/LS matches; this is not exhaustive or transitive proof. Main review records all gates false.
- [x] Current worker operations used the phase worker attempts and three authorized docs; no manual `/tmp` or HOME-root creation, deletion, install or product-file changes were performed. This is not proof that system tooling had no other side effects. The previous `/tmp` cleanup incident remains unresolved.
- [ ] Main performs the final audit and closes the phase; the audit artifact is `.build/automation-binder-composition-20261103/main-final-audit.json`.
