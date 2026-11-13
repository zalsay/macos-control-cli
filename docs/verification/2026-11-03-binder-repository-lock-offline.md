# Repository / launch context / original lock — offline verification

## Result and authority

The main Agent's `.build/automation-binder-repository-20261103/main-code-review.json` records `acceptedOfflineImplementation: true` and no unresolved code finding in the approved offline fixture scope. This is staged implementation evidence, **not product integration or GUI acceptance**. The main-owned final audit is authoritative **以其实际路径及内容为准；本报告不替代 audit**. The results below are the main Agent's independent results; worker runs are separate and are not added to the main counts.

The fixed source baselines are:

- Provider: `.build/automation-binder-repository-20261103/worker/attempt-031-task2-final-sourcefreeze/`; source-manifest SHA-256 `35f4938facf8452627438d6c2898f3b0daab960277bc5ccac65c4ebd4cd9fe72`.
- Integration: `.build/automation-binder-repository-20261103/worker/attempt-040-task3-final-sourcefreeze/`; source-manifest SHA-256 `34b2f93f660a3c1b62d6884dc4b1f4eed40f6d080e2ca7f6e69476ae2022e790`.
- Main source/build/fixture records: `main-review/provider-source-baseline.json`, `main-review/provider-builds.json`, `main-review/integration-source-baseline.json`, `main-review/integration-builds.json`, `main-review/integration-root.json` under `.build/automation-binder-repository-20261103/`. Exact recorded commands and individual logs are in those main-owned records; this document does not replace them.

## Main independent execution: 81 top-level CLI calls

| Category | Calls and result | Evidence |
|---|---|---|
| Original ProfileLock reference | 1 reference program: original live contention, release and unlink/new-inode behavior | `main-review/original-lock-reference.json` |
| Original-lock/directory primitives | 2 programs: normal and ASan, each 14 assertions | `main-review/ownership-primitives-results.json` |
| Concrete provider | 46 programs: 23 normal + 23 ASan; typed exact expected results | `main-review/provider-summary.json`, `main-review/provider-results.json` |
| Channel controller | 20 calls, classified below | `main-review/integration-summary.json`, `main-review/integration-results.json` |
| Post-child-exit original API lock probe | 10 calls: acquisition at the **current pathname** after observed owned-child exit | `main-review/integration-postexit-lock-probes.json`, `main-review/postexit-lock-probe-interpretation.json` |
| C collector compatibility | 2 programs: normal and ASan, old 64 MiB/new 1 MiB limits, wrapper limits and NULL API | `main-review/collector-compat-results.json` |

The 20 controller calls are **8 normal business flows with exit 0**, **8 expected fixture rejection assertions with exit 0, not business success**, and **4 original resource/peer negative cases with expected exit 78**. The eight normal flows include repo-bound normal ×3 and ASan ×1, plus legacy unbound and Profile-bound normal/ASan one each. Fixture rejection causes and `laterClosed` are asserted separately from endpoint peer-close tail observations.

The 10 lock probes show that original `ProfileLock.acquire` can acquire the current path after the owned child exited; they are **not inode-attested proof that every original held inode was released**. In the two lock-unlink cases the current path denotes a new inode, so that probe cannot prove release of the old unlinked inode. The separate owned-child exit observation and the original-handle/source evidence remain relevant; do not conflate them with the current-path probe. No PID scan or observed-PID cleanup authority is inferred.

## Collector, reuse and fixture audit

The original C collector is shared: the original 64 MiB cap remains on old snapshot/static/self/peer paths, while the repository wrapper supplies its own 1 MiB bound. The new exported comparison wrapper returns 0 on NULL without changing the original internal comparator. The main repo-normal image was **1,985,072 bytes** and completed its normal flow, providing a practical check that the old image path was not globally limited to 1 MiB. Independent compatibility tests and `main-review/collector-analysis.json` report successful normal/ASan runs and zero clang diagnostics; this is not a formal memory-safety proof.

`main-review/integration-reuse-check.json` records byte-identical reuse of the prior Control, Transport, KernelIdentityBridge, BundleResourcePin, BundleBindingTests, ProfileBindingTests and original owned-process cleanup section. `main-review/integration-no-gui-audit.json` distinguishes the **legacy normal image, with no repo-fixture hooks**, from the **repo-bound fixture, with its explicit synchronization hooks**. In each inspected binary, the four audited collector symbols (`bi_capture_peer`, `bi_snapshot`, `bi_snapshot_limited`, `bb_inventory`) occur once, and the direct dependency/symbol audit found no direct GUI/input/permission/LaunchServices dependency. This is a direct static audit, not exhaustive proof of transitive dependencies or runtime behavior.

The repo fixture's observation socketpair only coordinates test ACK/bind/mutation barriers. It is not the application control protocol, peer authentication or a GUI grant. Mutation cases wait for the real ACK and both fixture bindings before mutating, rather than relying on a sleep.

## Development evidence and scope

Compile RED for absent interfaces is retained in worker attempts `001`, `004`, `006` and `020`. The NULL-wrapper crash RED is retained in attempt `028`. The real recheck mutant's behavior RED is in `attempt-039-final-runs/mutant.log`: it includes the literal `MUTANT_DETECTED repositoryChangedFrameAccepted=true` after the changed-context send succeeded. The earlier generic-only mutant log in `attempt-034-task3-runs/mutant.log` is retained but cannot attribute its failure to accepted changed-context traffic. These are distinct kinds of evidence; no per-negative behavioral-RED coverage is implied.

The `executablePath` argument to `RepositoryBindingProvider.make` is a **caller-supplied, previously kernel-verified path**; the constructor does not authenticate it again and is not standalone production authority. A complete provider read uses one C monotonic deadline derived from the current original frame's remaining budget; the caller rechecks the original deadline and cancellation/generation afterward. The existing ceilings are 3 seconds per frame and 45 seconds for the connection. An OS call already blocking cannot be forcibly interrupted by these checks. Original arguments are generated and the actual child parses them, but kernel argv attestation is not claimed.

Snapshots and pre/post checks do not provide an atomic cross-file transaction, and they do not prove protection against malicious same-UID races, FD transfer/delegation or exhaustive memory/thread failures. No real profile repository or credentials were needed. GUI ownership, direct-human grant, real mouse/keyboard coexistence and real GUI acceptance remain unverified; GUI provider remains hard unavailable.

All gates remain **false**: `fullP1`, `G1`, `G5`, `input`, `shipping`, `liveAdapter`, `GUIExecutionAuthorized`, `manualGrant`, `ready`, `armed`. The code remains staged; it is not integrated into product Sources/Tests/scripts/Package and has not been installed, committed or pushed by this work.

## Execution discipline is separate and non-clean

`main-code-review.json` records `executionDiscipline.clean=false`. The worker wrote a source aggregate outside the authorized roots, then after a `/tmp` glob-removal command was rejected used Python glob/unlink for the same class of deletion. No pre-delete inventory exists, so the historical matching file set and impact are unknown. The worker acknowledged this; the evidence is `main-review/worker-temporary-path-deviation.json`. Independent code/test success and separate protected-project-file hash checks **do not erase or resolve this deviation**.
