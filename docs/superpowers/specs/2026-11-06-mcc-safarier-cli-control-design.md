# Safarier CLI control design

Status: direction approved by the user on 2026-11-06 with “按照建议继续”; implementation and runtime acceptance are separate gates. Terra implements; main alone reviews. Branch: `mcc-safarier`.

## Goal and existing path

Expose MCC-style CLI calls to the existing GUI Manager, authenticated Runner channel and owned-page native input. The CLI does not execute AppleScript text or use OSA. Its persistent controller sends typed `SFAu/requ` Apple Events using native APIs. MCC is a command/daemon reference only; its global CGEvent executor is excluded.

The current Manager owns `AutomationManager`; its actual Apple Event UID/PID/audit-token caller proof binds a session to one process. Independent short CLI invocations therefore use a persistent CLI controller, whose native sender identity remains stable. The Manager–Runner socketpair is not exposed to CLI clients. Existing profile/launch commands remain independent. The GUI Manager may remain visible/regular; native input belongs solely to its exclusive Runner WebView.

## CLI and local transport

The existing executable gains the `control` namespace before normal CLI workspace construction. Help and malformed arguments must not create workspace/runtime files or launch processes. The executable can run the CLI controller role without creating an NSApplication or registering a second GUI Manager. A read-only live capabilities probe must verify this assumption before business input; a duplicate receiver fails closed.

Commands: `daemon start`, `daemon serve`, `daemon stop`, `status`, `capabilities`, `connect` with explicit profile UUID, `state`, `observe`, `navigate`, `move`, `mouseDown`, `mouseUp`, `click`, `type` (including stdin), `press`, `cancel` and `disconnect`. Input requires the connection and a current frame ID. Coordinates are screenshot pixels converted using the actual frame scales. No arbitrary JSON/eval or guessed window/PID target is exposed. Connection/frame handles are opaque UUIDs; the Manager session token stays only in controller memory.

The private Unix socket is a CLI-controller ingress, not a new Manager or Runner listener. Runtime directory mode is 0700; socket mode is 0600. Reject symlinks, owner/type/inode changes and stale instances. A public nonce hello precedes payload delivery. Both sides authenticate the actual kernel socket peer using UID, audit identity/pidversion, birth, canonical executable path and dynamic signed-code identity against the pinned CLI image, and keep the peer alive until acknowledgement. No payload PID or PID file conveys identity, routing or termination rights. Existing Binder functions restricted to actual parent/owned child must not be repurposed for unrelated CLI peers; the new peer adapter is separate.

One ordinary operation per connection is admitted; reserved cancel/close capacity remains available. Requests and replies have strict schemas, bounded 65,536-byte frames and matching request IDs. Never automatically retry an unknown input/open outcome. Controller death leaves the original Manager lease and Runner lifetime cleanup authoritative; it never invents a cleanup receipt. Daemon stop exits only when sessions have already been confirmed closed and no opening or other operation remains uncertain or in flight; it does not close sessions on the caller’s behalf, quit the GUI Manager, or force-stop a session or discovered process. The controller replay window is finite (256 entries); when full, first complete real cleanup, then stop and restart the controller. The 45-second Binder lifetime is not renewed.

Native Apple Events address only the reviewed bundle identifier. Check unique receiver, exact app/executable/native handle, UID, birth and signed bundle before/after sending; validate OS reply sender identity. Never address by PID. Consent preflight is false; sending forbids interaction, recording, layer switching and consent prompts. The existing Manager caller proof remains real OS evidence.

## Native navigation

Ordinary input retains its 5-second budget. An explicit `--wait-navigation` input command maps to `navigateByInput(input:viewVersion:)`: unshifted Enter or a single click. It uses the original 30-second navigation transaction and preincrements the viewport exactly as URL navigation does. It is not an extension of ordinary key/click deadlines. Held state, stale input version and out-of-bounds clicks are rejected before dispatch. Existing actions retain their wire encoding; unknown fields and action/result mismatches still fail closed.

The page performs actual existing native input against the old lease and version. It first arms one private source-page authorization tied to exact owned objects, context, geometry and command generation. The actual owned main-frame navigation action is held until native delivery/drain and original input-activity close are confirmed; only then may the one policy decision be allowed. Its observed target is not a caller-provided identity. The next matching native navigation start consumes that authorization, after which existing commit/finish and bounded continuation rules apply. There is no derived form-URL load, DOM event simulation or global fallback. Enter retains the existing ordinary text/search responder eligibility checks. Cancellation/block/destruction cancels any held policy completion exactly once.

The explicit input action returns `navigationFinished` only after the real final native finish and replacement input readiness. Non-navigating input stays a separate command. An idle page cannot acquire a navigation permit from a caller URL, stale event or unrelated frame.

## Preserved constraints and boundaries

- Original Manager UID/PID/audit proof, session caller binding, Binder C identity and bundle inventory checks remain effective.
- Profile automation defaults off; existing human profiles are not taken over. Ephemeral/direct/no-SPI restrictions remain.
- Navigation 30 seconds, ordinary action/hold 5 seconds, cleanup 2 seconds and Binder lifetime 45 seconds remain unchanged. A persistent controller does not renew or silently recreate an expired page session.
- Real close proof remains `cleaned=true` and `terminatedOwnedRunner=true`, actual page/input/storage cleanup, plus empty owned artifact storage. Exit alone is insufficient.
- Controlled-page visible observation remains inactive/non-key/non-main and ignores physical mouse input. Normal user-requested Manager opening may activate once; CLI input never activates it or the Runner.
- Wheel remains disabled. No global input, System Events, new WebKit hook, CAPTCHA solver, proxy/storage/UA experiment or automatic foreground handoff.
- CLI is an engineering interface, not an anti-bot guarantee. Google CAPTCHA/search-result acceptance remains separate from native delivery/navigation acceptance.
- Existing user Manager stays open during offline work and read-only probes. Any necessary replacement of a possibly edited live Manager is a concrete final GUI-test decision, not an excuse to alter routing rules.

## Acceptance

Use small parser/protocol/peer and session tests; do not repeat broad matrices. Build a new immutable testing app, independently verify source/artifact/signature/role/root pins, then probe capabilities against the existing Manager. Run a focused native input and native form-navigation scenario through distinct CLI processes; verify same controller sender, exact page/viewport, real screenshot effect, no interference and real close proof. A Google attempt may demonstrate navigation to a challenge without proving search success. No installation, commit, push, merge or release is part of this work.
