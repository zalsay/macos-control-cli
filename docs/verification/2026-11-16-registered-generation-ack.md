# Closed registration reported busy; generation descriptor lifetime

Baseline: `b690c60`, branch `mcc-safarier`, preserving all existing uncommitted
control, navigation, authorization, DSH and ACP work.

## Exact SESSION_BUSY request

The user supplied request `2D158E5E-D96E-4C95-B2F5-81E90E307AF8`.
At 15:03:40 local log time, Manager PID 86052 returned an authenticated
`SESSION_BUSY` from `RegisteredRunnerChannel.openGeneration`, before a new
generation was sent. This predates the subsequent App replacement/restart.

The earlier navigation `4E45E556-4FF5-4FCC-B08F-B9100EC9C185` revoked its
generation. Runner's root failed with `BACKEND_UNAVAILABLE`; Manager's
`confirmDrained` closed its root at 14:57:47.689. A failed drain deliberately
retains the pending epoch and permanently closes that registration. However,
`openGeneration` checked the pending epoch before the terminal closed state.
Consequently a dead registration was incorrectly reported as a live busy one.

The existing admission now returns `BACKEND_UNAVAILABLE` for a closed root
before considering a live pending generation. The epoch is not erased and no
release proof, new registration, retry or process-exit claim is synthesized.
Restarting only the CLI daemon cannot repair that Manager-owned root.

## Transport reproduction and existing handoff correction

The first focused test run unexpectedly reproduced pre-hello EOF in the actual
descriptor-transfer test. With existing I/O diagnostic labels enabled, another
bounded run reproduced EOF despite the Manager's successful hello write.

A separate Python reproducer uses only Unix socket pairs, SCM_RIGHTS,
F_DUPFD_CLOEXEC and ordinary close/read/write. In the saved 10,000-cycle
comparison, closing the sender's original generation endpoint before the
receiver obtains/adopts its descriptor produced **5 unexpected EOFs**. Retaining
it until adoption produced **0/10,000**; retaining it through hello also produced
**0/10,000**. An earlier comparison observed 6/10,000 versus 0/10,000. This
characterizes the local platform behavior; it does not establish a general
POSIX guarantee or prove that every historic EOF has this cause.

`openGeneration` previously closed `pair.child` immediately after sending its
descriptor, before reading `accepted`. It now retains that original endpoint
until the existing authenticated root delivers `accepted` with the matching
epoch. Runner sends that frame only after descriptor adoption. The existing
deadline, post-ACK identity check and all failure cleanup remain. No frame,
authority source, wire protocol or fallback path was added.

## Focused validation

`RegistrationDescriptorTransferTests` and `RegisteredGenerationEOFTests`:
**11 tests passed**. The actual transport test now follows the acknowledged
handoff and completes 1,000 hello/reply cycles with unrelated descriptor churn
and a delayed read. The cross-process test retains its original endpoint until
the child's adoption ACK, then validates hello/reply. These transport tests do
not instantiate the signed `RegisteredRunnerChannel` identity context; the
production call ordering was reviewed by the main agent. No full regression
suite ran.

Private evidence: `.build/registered-ack-20261116/` for the raw reproducer,
package and installed review; `.build/navigation-receipt-20261116/` for the
exact busy trace and focused red/diagnostic/green logs. Full installed connection,
page observation and release results are recorded separately below.

## Installed package and live verification

Testing release attempt:
`attempt-20261116-155049-05e16f57e4c84eba9eebfad16cb8ac5a`.
All 150 source inventory entries match the installed build. All 12 pins,
namespace and strict signature validations passed for fixed and installed App
copies. Sidecar: `dist/releases/registered-ack-testing-20261116-155225`.
Installed App: `/Users/yingzhang/Applications/Safarier AI.app`.
DSH remains `0.2.2-rc.2`; its service was restored through the existing DSH pane.

The existing 新媒体运营 environment completed connect → observe → release:

- Connect request `FA15446F-11E0-4D30-9052-4E2BFE1A504E`: `ok`, 12.898 s.
- Observe: `ok`, 5.244 s. Screenshot visually confirms the existing Google
  results for 小红书笔记优化方案. No Google/Bing navigation or search was submitted.
- Release: `ok`, 8.237 s; all four receipt flags are true and identify the
  original profile/window/page. The test daemon then stopped successfully.

A separate ephemeral profile completed the loopback navigation fixture:
connect 11.730 s, screenshot before navigation, navigate 7.837 s, screenshot
after navigation, release 8.053 s. Navigation returned `ok`, `viewVersion: 2`.
Runner logged two `load.same_document.accepted` callbacks before normal
`didFinish`; the screenshot shows `SFA HISTORY RECEIPT READY`. All four release
flags are true; daemon stop succeeded. This validates the previously installed
same-document correction with the actual packaged CLI path on a fixture, not
a repeated Google search.

One earlier fixture attempt failed at root establishment with
`collector_bundle_4` (`BB_CHANGED`), before generation transfer or navigation.
Its creation of a home-directory runtime overlapped root capture; ancestor
metadata checks make that a possible test interference, but the failing C
comparison was not identified. This separate transient snapshot failure remains
unresolved and is not claimed fixed by descriptor retention. The later fixture
round succeeded without weakening identity validation.

## Cleanup error and recovery

During cleanup the main agent mistakenly selected original profile
`47064E43-9937-4DCA-AD04-0986E618FF3D` (本地inboard), instead of reading the
first fixture's actual UUID `5BE04F17-97EC-4294-8614-AF79928FDA45`. The original
record was deleted without `--purge-data`. Its exact profile record, original
UUID and session were restored from this run's pre-operation backup, and the
deletion tombstone removed while holding its existing bookmark transaction
lock. All three original profile records now match the backup; all original
window/tab URLs match (My 6 tabs, 新媒体运营 1, 本地inboard 1).

The deletion path also removes a profile's bookmark and credential metadata
files if present. No pre-operation backup/inventory of those two files exists
for 本地inboard, and no local Time Machine snapshot is available. Their prior
presence and any resulting loss cannot be confirmed. Persistent WebKit website
data was not purged. The error and this limitation were disclosed to the user.

Both actual fixture records were subsequently verified against their creation
receipts and removed; fixture browsers, daemons and loopback server were
stopped. The original two daemon runtime directories were restored after
checking and removing their stale, non-listening sockets. No release proof was
inferred from process shutdown. Changes remain uncommitted and unpushed.
