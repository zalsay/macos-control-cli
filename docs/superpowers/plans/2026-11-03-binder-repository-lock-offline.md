# Offline repository and original-lock binding implementation plan

**Goal:** Bind an authenticated real CLI fixture child to a private real-format ProfileRepository content/instance observation, original launch context and endpoint-owned original ProfileLock.

**Architecture:** The staged concrete provider and the original connection generation/gate are used only by offline CLI fixtures; the full data observation is rechecked. Design: `docs/superpowers/specs/2026-11-03-binder-repository-lock-offline-design.md`.

**Constraints:** No product source, test, script, Package or old-stage edits; no GUI/TCC/real repository/credentials, installation, commit or push. Preserve per-attempt sources, logs and receipts. Original lock acquire/release and original owner-plus-fresh-metadata cleanup remain unchanged.

## Evidence-backed checklist

- [x] Stage original ProfileLock with only same-object, no-FD-escape observation. The independent original-lock reference demonstrates live contention, release and the different-inode unlink behavior; independent normal/ASan primitive programs each report 14 assertions. `main-review/original-lock-reference.json`, `main-review/ownership-primitives-results.json`.
- [x] Pin fixture root, workspace and locks directories and preflight exact lock path; provider owns the original lock only in the runner role. Independent provider cases cover directory, lock and repository replacement and unsafe paths. `main-review/provider-summary.json`, `main-review/provider-results.json`.
- [x] Carry complete repository bytes and instance observation, compare SHA and original decoded records/repository `all`, reject duplicate UUIDs and invalid inputs. Keep format version separate from observed file version. Independent provider: 23 normal + 23 ASan programs, each with typed expected result; `main-review/provider-summary.json`.
- [x] Reuse shared C collector with an internal per-call repository limit; retain old 64 MiB paths, validate bounded wrapper limits and NULL guard. Normal/ASan independent compatibility results: `main-review/collector-compat-results.json`. Main reports clang diagnostics zero in `main-review/collector-analysis.json`.
- [x] Bind the concrete provider to the original connection generation/pending/gate; recheck full observation around I/O, use one C deadline per read derived from remaining original frame budget, and retain one-shot cancellation/revocation. Main independent reuse checks and code review: `main-review/integration-reuse-check.json`, `main-code-review.json`.
- [x] Retain trusted spawn spec, generate original arguments and parse actual child arguments; test explicit mismatch. This establishes no kernel argv attestation. `main-review/integration-results.json`.
- [x] Build and sign separate precreated fixture roots; exercise real-child repo-bound normal ×3 and ASan ×1, exact-error mutation/lock/argv negatives, selected legacy/profile and resource/peer cleanup cases. Main's 20 controller calls and their separate classifications are in `main-review/integration-summary.json`; worker logs are not added to these counts.
- [x] Preserve distinct test-development evidence: compile RED for missing staged interfaces (`worker/attempt-001-lock-red`, `worker/attempt-004-directories-red`, `worker/attempt-006-provider-red`, `worker/attempt-020-deadline-red`); NULL comparator behavior RED (`worker/attempt-028-null-red`); and an attributable recheck mutant behavior RED with literal `MUTANT_DETECTED repositoryChangedFrameAccepted=true` (`worker/attempt-039-final-runs/mutant.log`). The generic-only mutant in `worker/attempt-034-task3-runs/mutant.log` is retained but is not evidence of that specific cause. No claim is made that each individual negative had a separate behavioral RED.
- [x] Freeze independent provider at `worker/attempt-031-task2-final-sourcefreeze` and integration at `worker/attempt-040-task3-final-sourcefreeze`; preserve independent main review and verification evidence. No further worker HOME changes or build/run are part of this documentation synchronization.
- [x] Synchronize the authorized verification document. Review decisions and final SHA/audit ownership remain with main; the authoritative final audit is the main-owned `final-audit` result/path, not this report.

## Remaining product boundary

- [ ] Real GUI ownership, direct-human grant, foreground/input coexistence and associated GUI acceptance are unverified. All listed readiness/authorization gates remain false; the staged fixture is not integrated, installed or released.

## Execution-discipline exception

The attempted source aggregation outside the authorized write roots, followed by a rejected `/tmp` glob removal and a Python glob/unlink alternative, was a scope and refusal-bypass deviation. There was no pre-delete inventory, so the historical matching set and impact cannot be established. The main records `executionDiscipline.clean=false`; code acceptance and successful tests do not resolve it. See `main-review/worker-temporary-path-deviation.json` and `main-code-review.json`.
