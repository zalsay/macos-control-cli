# Registered generation hello EOF

Baseline: `b690c60`, branch `mcc-safarier`, with the existing uncommitted preparation, uncertainty-admission and DSH rc.2 changes. This investigation concerns the user's failed post-upgrade connect; it is distinct from the earlier preparation deadline.

## Observed failure

Request `1CCE8A46-706D-45C9-938F-6131D6594938` reached the installed Manager (PID 47930). Its registered Browser (PID 47997) remained running after the failure. Root establishment had completed successfully at launch.

The Runner completed context installation in 1,231 ms, then the first generation hello receive returned EOF. Its first recorded generation close was `AutomationRunnerServer.stop()` at monotonic_ns `11521475013208`. Manager reported `CONTROLLER_HANDSHAKE_DIAG stage=receiveReady error=automation_RUNNER_EXITED` at `11521475494750`, then closed its generation and root. The Runner subsequently reported root closure and retained its human browser. No registered preparation or page attachment was reached. This does not establish why the initial receive returned EOF, nor prove process exit.

Preserved evidence: `.build/runner-exited-20261116/{profile-failure.log,root-unified.jsonl,unified.jsonl}`. These are private local evidence and can contain environment metadata; no token or page content is reproduced here.

## Narrow reproduction and instrumentation

A new test in `RegistrationDescriptorTransferTests` exercises the actual root descriptor-transfer methods, closes the sender's original endpoint, adopts the received endpoint, churns unrelated file descriptors, delays the first framed hello read and checks a reply. All 32 iterations passed in both debug and release builds. These are same-process transport observations, not signed App or browser acceptance.

The additional `CHANNEL_IO_DIAG` records generation read/write system-call byte counts, errno and descriptor type. It records no frame bytes, tokens or page data. Read errno is captured before diagnostic calls and used unchanged for error handling. No timeout, admission or recovery behavior is changed. This is instrumentation, not a claimed fix.

Focused diagnostics/transport selection: six tests passed, zero failures. No full regression was run. Main-agent review checked descriptor ownership, cancellation, error preservation and absence of payload logging; `git diff --check` passed.

## First diagnostic App run

The first diagnostic package was built, checked and installed through the existing seven-stage release pipeline. Main review confirmed 150 source entries before/after/current equal, all 12 pins matching both copies, valid strict signatures, namespace, metadata and resources. Attempt: `attempt-20261116-114838-f4cf70a5bf824c6caa2a58fcfe446534`.

After normal quit and session backups, the existing target was restored without an explicit URL. The single probe failed before a connection was returned, so no state or release was attempted. Runner PID 54749 returned `readHeader requested=4 result=0 errno=0 descriptorKind=49152` (a socket) at monotonic_ns `12475222455041`. Manager PID 54732 subsequently returned `write requested=154 result=-1 errno=32 descriptorKind=49152` at `12475722988000`; its handshake failed at `sendHello`. Both processes remained alive. This proves a real EOF followed by EPIPE, but still does not identify the first cause.

The ordinary My profile rejected `sfa launch` with `PROFILE_NOT_ALLOWED` because its Agent switch remains off. It was restored through its existing ordinary Runner entry, with that switch unchanged. Session counts saved at quit were My 7 tabs and 新媒体运营 2 tabs.

A separate process test uses the real sender and a Python subprocess receiving SCM_RIGHTS; it closes the sender endpoint, reads a framed hello and writes a reply. It passed in debug and release. The seven-test diagnostics selection passed. Additional diagnostics now compare the kernel's opaque socket/peer handles before transfer, on receipt and on I/O. These handles are diagnostic correlation only and are never used for admission or identity.

## Socket correlation and final diagnostic package

The package with pre-transfer socket observations completed two connect → state → release rounds against the same target. A later fresh-root attempt passed hello/ready but failed during initial page admission because the restoring browser became active (`REGISTERED_ADMISSION_DIAG reason=appActive`, `INTERACTION_REQUIRED`); the public connect reply was `BACKEND_UNAVAILABLE`. This is a separate page-admission failure, not hello EOF. After switching to Codex, two more rounds completed with confirmed release. No searches or page input were issued.

To reduce timing disturbance, the final package removes observations before transfer/adoption and retains only observations after actual read/write calls. It records the kernel's opaque socket/peer handles with the existing byte counts, descriptor type and captured errno. This does not change transfer ordering, timeouts, authorization, or recovery. The earlier pre-transfer diagnostics are absent from the final source.

Final attempt: `attempt-20261116-120253-aec2fa148af34aa5b15fea20c08d5c1b`. All seven packaging stages completed. Main-agent review again verified source-before/source-after/current equality (150 entries), both App copies' 12 pins, strict signatures, namespace, metadata and resources. DSH remains rc.2 with the existing reviewed sidecar anchor.

The final installed package then completed **two** connect → state → release rounds against the same Runner, window and page. Connect took 7.815 s and 13.234 s. Every release confirmed `inputReleased`, `artifactsCleaned`, `browserRetained` and `manualInteractionEnabled`, with the same target as state. The test daemon stopped successfully. Saved sessions remained My 1 window / 7 tabs and 新媒体运营 1 window / 2 tabs. Both human browsers and Manager were retained. Evidence: `post-io-live/`, `post-io-unified.jsonl`, `post-io-package-review.json` and `final-review.json` under `.build/runner-exited-20261116/`.

The final diagnostics/transport selection passed seven tests. The cross-process test was subsequently strengthened to duplicate/close the received descriptor as the Swift adopter does, acknowledge adoption, start its read before the Manager write, and delay hello; that changed test passed separately (`read-before-write-probe.log`). The earlier release probe predates this last test strengthening. No full regression was run.

**Status remains open.** Successful diagnostic runs do not establish that the intermittent pre-hello EOF is fixed. No root-cause fix, automatic retry, new PID adoption or error remapping has been introduced. Current logs can correlate the two socket endpoints if EOF recurs. All changes remain uncommitted and unpushed.
