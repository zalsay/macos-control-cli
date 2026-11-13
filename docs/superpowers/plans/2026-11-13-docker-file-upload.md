# Docker file upload implementation plan

User approved the proposed WSS file transfer + native Firefox picker on 2026-11-13. Execute inline; primary agent owns review. Preserve the existing default desktop and unrelated changes.

**Goal:** An external MCC CLI sends a local file through the authenticated Host and selects it in a native Firefox picker; a real fixture web server receives identical bytes and the original filename.

**Existing flow:** Host WSS already authenticates sessions and reserves the sole desktop owner; screenshots use bounded binary frames. Remote select-file currently permits only explicitly allowed Host paths, Service restricts it to Chrome, and Linux helper rejects it. Extend these owning paths instead of introducing another executor.

**Contract:** `mcc --remote ... file put --connection ID --local /absolute/file` returns fileId/name/bytes/sha256. `select-file --connection ID --file-id ID` resolves only files uploaded by that session/connection. Existing `--path` semantics and default-denied roots remain intact. Host opts in with `--upload-dir`; Docker uses an independent private transfers volume. No shell, Docker socket, DOM injection, WebDriver or automatic web submission.

**Limits:** One file per call, at most 64 MiB, 32 KiB binary chunks, bounded transfer time, 256 MiB/128-entry disk quota. Private staging directory, exclusive/no-follow creation, SHA256 check before publication; failed/incomplete transfer cleans staging. Completed files retain original basename and are scoped to the live Host session and connection. Disconnect removes that connection's completed uploads; crash leftovers remain quota counted and need explicit local cleanup.

- [x] Add failing CLI/protocol tests and reproduce missing Linux select-file with a real native picker.
- [x] Extend existing args/client/wire/Host/session handling for a single manifest + binary transfer and a ready acknowledgement, preserving owner, sequence and cancellation guards.
- [x] Add a focused remote files module for safe staging, quota, hashing, ownership, file resolution and cleanup; test corrupted, truncated, replaced, cross-owner and traversal cases.
- [x] Extend the existing Service and Linux/X11 adapter to select an identity-verified Firefox GTK file dialog using the existing input primitives and release/pause gates. Only that verified modal may keep its parent's focus lease.
- [x] Add an external fixture smoke: transfer from host, reject another session, system click opens picker, file-id selection, real multipart upload, compare filename and bytes. Include no-dialog and pause negatives.
- [x] Add Docker transfers volume/startup opt-in, update docs, build and run targeted Rust tests and live ARM64/AMD64 checks as practical.
- [x] Main-agent review, clean isolated resources, update default container without replacing profiles, and deliver exact commands and validation limits.

Evidence and final image IDs: [validation report](../../MCC-DOCKER-VALIDATION.md#文件传输与原生上传增补验收). Both architectures passed the external multipart upload smoke; the default desktop preserves its original volumes and credentials, adds the private transfers volume, and reopens the `google` profile. Physical Ubuntu x86_64 was not tested. No commit or push.
