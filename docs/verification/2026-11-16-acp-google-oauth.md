# ACP Google OAuth: callback handling and account network configuration

## Observed failure

The user clarified that `Could not deliver the sign-in response. Start sign-in
again.` occurred after pasting the localhost redirect and pressing Continue.
It did not occur while launching Chrome. Chrome is the system HTTP/HTTPS
handler; a harmless local launch fixture was received with a Chrome user agent.

During a fresh user-driven Google login, the managed Antigravity 1.3.0 process
73110 listened on `127.0.0.1:59254`. The user reported localhost success in
Chrome. The listener then disappeared while the same process remained alive,
and ACP still waited for native verification. Reposting that redirect targets a
listener that the browser has already used. The plugin controller treated any
callback forwarding error as grounds to cancel the native login process,
interrupting any remaining token exchange or verification.

An independent network issue also prevented completion without reposting:
the account had an empty environment, the backend connected directly to Google,
and sign-in ultimately failed without saving a token. A credential-free probe
of `https://oauth2.googleapis.com/token` timed out directly, but returned HTTP
404 through the current macOS system HTTP proxy (CONNECT 200). HTTP 404 is
connectivity evidence only, not evidence of authentication.

## Corrections

The active `dsh-acp-agents` 0.4.8 is linked to:
`/Users/yingzhang/Documents/deepseek-harness/default-workspace/dsh-acp-agents-local`.

Updated its existing controller at
`tools/runtime-build/upstream/apps/server/src/provider/AntigravityAuth.ts`:

- A callback delivery failure no longer stops the native authentication flow.
  The same still-pending flow can accept a corrected manual redirect.
- A cancelled, replaced, or already-verifying flow is not restored by a late
  forwarding failure. Confirmed native success takes precedence over that failure.
- The error now explains that a browser may have already delivered the response.
- Original callback origin/path/state validation, the five-minute authentication
  deadline, explicit cancellation and native authentication decisions remain.
  Delivery alone never authenticates the account; there is no automatic replay.

Rebuilt `lib/vendor/agent-runtime.cjs` with the existing runtime build script.
Reviewed the generated diff against its original: only the controller changes
above appear. Original line endings were preserved, and the regenerated
`mcp-bridge.cjs` was verified equivalent and restored byte-for-byte.

Using the account's existing environment configuration, set only Antigravity's
HTTP_PROXY and HTTPS_PROXY to the current local system proxy
`http://127.0.0.1:7897`, and NO_PROXY to `localhost,127.0.0.1,::1`.
This is local account configuration, not a hard-coded proxy in source or a
global proxy change. The original account file and source/bundle files are
backed up privately under `.build/acp-oauth-20261116/`.

Safarier application source, runtime image and app bundle were not changed for
this correction. No app repackaging is needed for the linked plugin. Replacing
that link or reinstalling the upstream plugin can overwrite the local code fix.

## Verification

Added `tests/antigravity-callback.test.mjs` in the linked plugin. It exercises the
actual bundled controller, local HTTP listeners and its native-runtime seam,
without real Google credentials or production child processes.

Before the fix, the duplicate-delivery test reproduced native authentication
being interrupted. All five focused cases pass after the final build:

1. Browser already received the callback; a duplicate cannot abort native login.
2. Manual callback delivery works and still waits for native verification.
3. Native verification failure remains a failed login.
4. Explicit cancellation during forwarding remains cancelled.
5. Native success racing a forwarding failure remains successful.

Wrong-state callbacks reject before delivery. The concurrent-success test also
failed before its corresponding correction. No full regression suite ran.
Build and test output: `.build/acp-oauth-20261116/build.log` and
`callback-green.log`. Source and generated output were reviewed by the main agent.

## Actual local acceptance

DSH was restarted via the existing native Restart Service menu, initially
69880 → 76965. With the corrected account configuration, the user completed
Google authorization in Chrome and ACP displayed `已登录` and
`Signed in with Google.`. A token file and authenticated account marker were
saved; their contents were not printed.

After final review, DSH was restarted again (76965 → 78734) to load the completed
runtime fix. The actual ACP interface still displayed `已登录`; the saved account
marker and proxy configuration were retained. The user independently confirmed
`ACP 已显示登录成功`. Manager 58512 and the original browser processes 58538/58541
remained alive throughout these DSH-only restarts.

Final account-file comparison also observed changes to this account's model
catalog and hidden-model selection during live acceptance; these were preserved.
All fields outside this account's environment, authentication marker, model
catalog and visibility were unchanged from the private backup.

This verifies Google sign-in and persistence for this account. It does not claim
a model inference, subscription entitlement, or browser takeover test.
