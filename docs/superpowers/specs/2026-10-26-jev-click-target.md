# Jev OCR semantic click contract

> Historical initial v0.2.5 contract. User amended provider/model/key loading to OpenRouter typesafe/jev-1.13 and cwd .env (v0.2.6), then explicitly removed the added OCR recheck and required original click gates (v0.2.7). Current contract: docs/JEV-CLICK-TARGET.md. Original native input checks and model-selection thresholds remain unchanged.

Approved in chat on 2026-10-26: a single `click-target --connection ID --target TEXT [--jev-key KEY]` operation, selecting an OCR candidate ID with Jev and reusing existing click gates. No autonomous loop, scrolling, alternate input path, or business-success claim.

- Reuse current checkout, no new worktree; changes isolated on `codex/jev-click-target`.
- Explicit key overrides `JEV_API_KEY`, then `TYPESAFE_API_KEY`; per-call only, never persisted/logged/returned. CLI flags can still enter caller shell history/process arguments; recommend environment variables. Missing/invalid keys fail before daemon startup. Never send keys to the native helper.
- Existing `observe`, pixel `click`, protocol v1, Chrome/desktop scopes remain compatible. Semantic actions serialize under the existing service lock, return BUSY rather than queue, and retain emergency stop behavior.
- Fresh same-frame OCR, <=128 candidates, original frame pixels; reject unavailable, truncated, empty OCR. OCR is untrusted data, not instructions, not button-role evidence.
- A single official TypeSafe HTTPS request asks Choice (candidate ID or none) and Noul (one unambiguous matching target exists). Fixed conservative initial thresholds: selected probability >=0.95, Choice confidence >=0.90, existence >=0.95, top-two margin >=0.20; selected OCR confidence >=0.80. These are uncalibrated deployment defaults, not accuracy guarantees.
- Only enumerated IDs may be used; validate the full probability distribution, finite/range values, selected argmax, and response types. No free-form coordinates or model-provided executable actions.
- Native guarded click checks observation input epoch across inference, plus complete OCR text/geometry after countdown and pointer motion, before mouse-down. Any pause/resume, unavailable/new/changed/truncated OCR, window identity/geometry/focus/ownership failure rejects; no retry/replay. No semantic guard on existing coordinate clicks.
- Guard freshness is bounded (initial observation no older than 20s before native request; fresh verification capture must finish within 5s). UI can change after the last screenshot: OCR does not prove enabled/clickable roles, and no atomic screenshot+click guarantee is claimed.
- Return selected candidate/coordinate, model confidence/probability, stage durations, `sent:true`, `effectVerified:false`, status `click_sent`. Never report business completion or retry an uncertain/partially dispatched click.
- Cloud request contains only target and OCR text/layout/frame dimensions, not screenshot files, paths, connection credentials or window titles. Only explicit click-target opts in to network use.
- Network: official HTTPS endpoint, 3s connect / 8s total budget, <=64KiB response, no retries/redirects, no raw HTTP error bodies in logs/results. Existing dependencies remain serde/serde_json; use system /usr/bin/curl with secret passed via stdin config.

Primary sources checked 2026-10-26: TypeSafe /api/system-one, /primitives/choice, /primitives/noul, /models. No API key or real GUI click is needed for automated fixtures. Live API accuracy, real UI hit and end-to-end acceleration require separate acceptance.
