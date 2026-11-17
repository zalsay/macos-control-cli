# Registered navigation: post-load page redirect closes the reply channel

Baseline: `61e714c`, branch `mcc-safarier`. Exact user request:
`F06B3E1A-76A6-47B7-888A-5472D2179FE7` (`navigate`). The external navigation was not replayed.

## Confirmed failure chain

Evidence: `.build/navigation-f06b-20261116/trace.ndjson`, `failure.ndjson`, and the existing profile's Runner log. Absolute timestamps below use the host log's UTC+08 offset.

| 2026-11-16 time | Event |
| --- | --- |
| 18:39:14.445 | Manager receives navigation |
| 18:39:21.856 | Page sink returns success |
| 18:39:22.323 | Runner handler returns success |
| 18:39:23.069 | Runner queues success reply |
| 18:39:23.406 | Runner writes all 140 bytes; Manager reads the complete frame |
| 18:39:23.500 | Runner closes generation after `mainExplicitURL` navigation-policy rejection |
| 18:39:23.570 | Manager's inbound peer validation fails; navigation returns `INDETERMINATE_RESULT` |

The original page reached `didFinish`. It then issued a new main-frame `.other` navigation, with its source URL equal to the current page. `finishExplicitNavigation` had already cleared `explicitURL`. The delegate only had the nonregistered fixture's continuation callback; registered attachment did not install one. It therefore cancelled this page navigation and called `beginClosing`. The peer channel disappeared while Manager validated the already received reply (`collector=peer result=1`, stage 16). This is different from the earlier bundle validation timeout and from waiting for navigation completion.

## Repair in the existing navigation path

- Registered attachment installs the delegate's existing continuation callback. An idle page may continue a main-frame `.other` HTTP(S) navigation only when both frames belong to the bound WebView, the source is the recorded current document, the current URL is the source or WebKit's new candidate, no pointer is held, and live context/registered target/window checks pass.
- The callback adopts WebKit's already initiated navigation through the existing submitted-navigation state and `didStart` correlation. It never reissues `webView.load` or replays the page request. Server redirects, commit/finish/failure, observation and release use the existing lifecycle.
- Idle `pushState`/`replaceState` callbacks update the recorded URL only for the bound live WebView, recognized same-document callback type, equal callback request/current URL and the same origin. Load-time and explicit input navigation retain their prior callback paths.
- Real transport, identity, ownership, download, unsupported scheme and uncorrelated-navigation failures retain their error paths. No generic success fallback or deadline extension was added.

## Validation

Only changed navigation policy, registered same-document handling and submission contract tests are selected; no full regression suite is run. The new live regression script is `scripts/test-registered-page-redirect.py`: it creates one ephemeral loopback fixture profile and a private daemon, sends one navigation, checks a post-finish page redirect and idle History API updates, observes the final page, verifies all four release fields, and cleans up only its own resources.

Initial installed baseline attempt (`red/`) did not reach navigation: the launch's read-only AppleEvents authorization path failed to return before the test's 80-second process limit. A separate read-only `authorize` returned `unavailable`, OSStatus `-1712`, with `businessEventSent=false`. The temporary profile was removed. This is setup blockage, **not** a behavioral RED or evidence about navigation.

The first unit-test run (`policy-red.log`) failed compilation because the newly named policy helpers did not yet exist; this is also not a behavioral RED. The subsequent focused run passed (see `focused-tests.log`). Signed-package/live acceptance results will be recorded below once observed.

### Final results

- `focused-final.log`: 16 selected tests pass (2 Core, 14 App), including the new source/current-document and idle History API policy cases. Existing Swift warnings remain in unchanged code. Main agent reviewed all changes; no delegated review and no full regression suite.
- Signed source build: `attempt-20261116-185222-6d82941a83c3416d839ce9684d513c93`; sidecar package `dist/releases/registered-page-redirect-testing-20261116-185323`. All 150 source inventory entries and all 12 pins/signatures checked. Installed App and fixed `dist/releases/Safarier AI.app` both validated. DSH stays at the reviewed `0.2.2-rc.2` artifact and `127.0.0.1:61919`.
- Original Manager/browsers quit normally, then five original daemon paths and both browsers were restored. Startup/launch returned after restart; this is not a diagnosis or a permanent fix of the separate authorization-query hang.
- First post-install fixture attempt (`green/`) reached connection but was denied because its browser application was active (`REGISTERED_ADMISSION_DIAG reason=appActive`). It sent no navigation. The test harness now explicitly activates the configured host app (default Codex) before connect, preserving the existing background admission check.
- Final installed live test (`green-background/`) passes. Connect: 8.457 s; navigate: 3.953 s (`navigationSubmitted=true`, `effectVerified=false`); state: 3.356 s (`/final?push=done`, loading false); observe: 4.017 s; release: 7.170 s, with all four fields true. Main agent visually checked `final.png`, which shows `REDIRECT FINISHED`.
- Runner logs record `page_navigation.accepted`, then two `idle.same_document.accepted` callbacks. The loopback request log has exactly one `/redirect` and one `/final`; no navigation replay. Own fixture browser/profile, daemon and HTTP server were cleaned up.
- 22 existing profile/subscription/bookmark/credential files match the before-quit bytes after fixture cleanup. Original saved tab counts (My 6, 新媒体运营 2, 本地inboard 1) and selected indices match the snapshot taken at normal quit. Session timestamps changed on restore; one 新媒体运营 tab's saved URL changed from the creator site's `/login` to `/new/home` after restore. This current state was preserved; no older session was written back. Before-quit and after-quit backups remain under the evidence directory.
- App restart invalidates old connection IDs, including the user's failed connection. A fresh `connect` is required. No external navigation/search was replayed, and this report does not claim a new Xiaohongshu end-to-end navigation test.
- Changes remain uncommitted and unpushed.
