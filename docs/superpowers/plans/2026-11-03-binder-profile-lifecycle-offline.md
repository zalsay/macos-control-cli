# Offline Profile binding implementation plan

- [x] Write `docs/superpowers/specs/2026-11-03-binder-profile-lifecycle-offline-design.md` and this plan; record scope and real call paths.
- [x] Copy previous `FullHarness.swift`, `BundleResourcePin.swift`, `KernelIdentityBridge.swift`, and fixture builder into `.build/automation-binder-profile-20261103/worker/`; use original C collector and inventory read-only.
- [x] Add executable failing worker tests (`worker/ProfileBindingTests.swift`); preserve RED logs and source SHA. Initial compile failure due to missing `ValidatableRecord`/`RecordRepository` is dependency RED, not evidence of target behavior. A separate no-profile-equality test variant should demonstrate mutation detection where feasible.
- [x] Extend existing `worker/FullHarness.swift` actor's private generation with a single exact snapshot, pending/reentrant poisoning and cross-await generation, deadline and cancellation checks. Resolve actual Profile and launch spec via `Sources/SafarierCore/RunnerPreparationPlan.swift`, with no outbound/credential readers. The default GUI provider denies and revokes.
- [x] Adapt `worker/make-session-fixture.sh` with explicit source dependencies; build/sign every fresh 0700 HOME fixture first, then run serial normal/ASan tests, recording exact commands and source hashes. Include legacy/default/duplicate, UUID collision, config mutation, repeat binding, cancellation/late callback, provider denial, resource mutation, peer exit and owned cleanup.
- [x] Record exact results and remaining gates in `docs/verification/2026-11-03-binder-profile-lifecycle-offline.md`; main agent alone reviews. No live GUI, authority or readiness claims.

- [x] Main agent independently validated and performed review; `main-review/summary.json`, `results.json` and `no-gui-and-reuse-audit.json` record the independent run and audit. The main agent’s formal review at `.build/automation-binder-profile-20261103/main-code-review.json` accepts the offline scope with no unresolved findings in that scope; final preservation is governed by `.build/automation-binder-profile-20261103/main-final-audit.json`. Any GUI acceptance plan requires separate approval and is not included here.

- [x] Preserve old-stage baseline and exactly recovered historic source digests in `worker/historical-source-archive/digest-index.json`; keep original manifests and logs unchanged. The index covers the entries in the main historical mapping, not a claim that every historical source outside it was preserved.

- [x] Main-agent final review: 40 additional typed Profile rejection-cause rechecks passed against unchanged implementation; these repeat the field/policy cases rather than adding feature coverage. See `main-review/domain-cause/summary.json`.
