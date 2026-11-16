# Navigation result misclassified after a same-document callback

Baseline: `b690c60` on `mcc-safarier`, preserving the previous uncommitted
authorization, DSH, ACP and control changes.

## Original failure

The user reported successful visible Google search results despite an
`INDETERMINATE_RESULT` response after approximately 4.30 seconds. Existing logs
correlate this navigation with request
`4E45E556-4FF5-4FCC-B08F-B9100EC9C185`.

The Runner logged explicit navigation start and commit. WebKit then delivered
`didSameDocumentNavigation` type 2, from the owned WebView, with a WKNavigation,
no initiating frame, and matching current/request URLs. No native-input permit
was present. The callback was rejected as `registered.sameDocumentRejected`,
which revoked the page and interrupted control. Manager returned
`INDETERMINATE_RESULT`; the AppleEvent sender authenticated that exact error
reply. The browser subsequently logged a normal `didFinish`.

Thus this was an application navigation-policy misclassification, rather than
evidence that the search was not executed or that the error reply was lost.
Visible page success still does not prove that input ownership was released.
The automatic close was logged as unconfirmed.

## Existing path corrected

Previously, registered same-document callbacks only had the native-click/Enter
permit path. Ordinary explicit navigation could not accept an in-page History
API update while the document loaded.

The existing callback now recognizes history updates during a correlated,
committed explicit load. It retains the original full-navigation object and
epoch, validates the owned WebView and target, and permits only recognized
history types with matching request/current URLs on the accepted response's
origin. Optional initiating-frame checks remain. The existing URL tracking is
updated so the original `didFinish` can validate the final address. A history
callback does not itself complete navigation or report success. Native-input
permit/document validation retains its existing path; the same-origin check is
shared rather than duplicated. No retry or synthetic success receipt was added.

WebKit upstream source independently confirms that History API callbacks can
carry a newly created navigation and that the private delegate callback is
delivered for the main frame. Reference source was saved privately with the
evidence; installed behavior was also characterized by a real WebKit test.

## Focused verification

All **14** tests passed in `RegisteredLoadSameDocumentTests`,
`RegisteredSameDocumentTests`, `RegisteredNavigationWatchdogTests` and
`InternalNavigationPolicyTests`, compiled with the testing App flags. No full
regression suite ran. The main agent reviewed the production and test changes.

The new real-WebKit test uses a nonpersistent, isolated WKWebView and a
loopback-only HTTP listener. A fixture calls `replaceState` then `pushState`
while an image delays load completion. Both actual callbacks are accepted by
the production correlation policy, and the original navigation still finishes.
It does not use a user profile, native input or an external website. A mutation
that rejects the acceptance branch makes this actual-WebKit test fail; the
reviewed source was restored and the final 14-test run passed.

The fixture's initial test failure was caused by reading the listener's port
before its ready state, yielding an about:blank page. The test now waits for
listener readiness. This was a test fixture correction, not an application fix.

## Package and actual CLI limits

The testing release was rebuilt, signed, packaged and installed using the
existing helpers. All **150** source inventory entries match the installed
build; all **12** pins and installed/fixed App validation passed. The DSH rc.2
runtime and external ACP plugin were not changed. Build attempt:
`attempt-20261116-151421-12962cbb7b6e455bb36c164e4bc8d33c`.

Manager, the two original environments and DSH were restarted after normal quit
requests and session backups. Original profile configuration is unchanged;
My retained one window/six tabs, 新媒体运营 one window/one tab. Temporary test
profiles and their browser processes were removed. Owned fixture servers and
temporary daemons were stopped; the original runtime directories have idle
daemons restored. None of these lifecycle operations is a release receipt.

Full `sfa` acceptance remains **unconfirmed**:

- Isolated-profile attempts stopped at connect with `RUNNER_EXITED`, before
  issuing fixture navigation. Logs include root/generation EOF and broken-pipe
  symptoms; these attempts do not test the changed callback path.
- A read/observe/release attempt against the existing environment stopped at
  admission with `mouseButtons` and returned `BACKEND_UNAVAILABLE`.
- After the user explicitly released the mouse and left the browser in the
  background, another connect did not return within the external 30-second
  watchdog. That owned query was stopped; no observe or release was issued from
  it because no connection identity had been received.

No new Google search navigation was submitted. The full control-channel and
four-field release confirmation remain unresolved, separate from the tested
same-document policy correction. No pending user readiness question remains.

Follow-up: the subsequent descriptor-ACK package completed existing-page
connect → observe → release and the isolated history-navigation fixture with
all four release flags confirmed. See
`2026-11-16-registered-generation-ack.md` for the exact requests, timings,
remaining snapshot failure and cleanup recovery limitation. Google navigation
was not repeated.

Private evidence, recovery paths and logs are under
`.build/navigation-receipt-20261116/`, including `installed-review.json`,
`session-preservation.json`, the original trace, real-WebKit mutation/final test
logs, fixture failures and connection attempts. Changes remain uncommitted.
