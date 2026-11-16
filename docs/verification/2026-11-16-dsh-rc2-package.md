# DSH rc.2 upgrade and local App package

Baseline: `b690c60`, branch `mcc-safarier`, including the existing uncommitted registered-prepare and uncertainty-admission changes. The user authorized repackaging the App and upgrading DSH to the author-validated rc.2 or later. This package selects exactly **0.2.2-rc.2**, published in the [official release](https://github.com/deepseek-ai/deepseek-harness/releases/tag/dsh-v0.2.2-rc.2). No newer-version validation is inferred from npm's tags (`latest` still pointed to rc.1; `next` pointed to rc.3).

## Runtime and source review

- Installed `@deepseek-ai/dsh@0.2.2-rc.2` into the existing private build tree through `scripts/build-dsh.sh`, explicitly using the official npm registry. The main package's SHA-512 integrity matched official registry metadata and the installed lock entry; all **532** published main-package files matched the verified tarball byte for byte. No upstream DSH source patch was added.
- Retained Node **24.19.0**, satisfying DSH's `>=24.9.0` requirement. Node SHA-256 remains `27db838bb204ef7c21df2931f5656e4c8fb32e6e947f363a402b49714d32b5b1`. Strict signature validation and the existing Security framework requirement for identifier `node` / Team ID `HX7739G8FX` passed.
- Generated a new runtime image with the existing preparation tool, verifying **101,416** manifest entries and **13** symlinks against its read-only mount. Image SHA-256: `53fad47a4ffc8cd0a8e9989ae619d1cfbe34618f7c9d921f52086ae4c5e01a9a`; manifest SHA-256: `b4f513bfec24a40c0f4d5cdb8181017f790ce7857a871e9a3ed5cd8165586c5a`.
- Updated the existing Swift/Python source anchors, their consistency tests, the build script's target version and the unified build's default artifact path. The reviewed material is at `dist/releases/2026-11-16-dsh-rc2/runtime-artifact`. The main agent reviewed these diffs.

## Scoped validation

The mounted image returned `0.2.2-rc.2` from the actual CLI. With an isolated empty HOME/DSH_HOME, sharp generated a PNG, koffi loaded, the system native addon acquired a real file lock, and node-pty spawned a short shell command successfully. The isolated Web server listened only on loopback, returned the expected unauthenticated HTTP **401**, and exited **0** after normal termination. This does not claim authenticated chat, search-provider configuration or model-request acceptance.

The first native probe used an unsupported package-root import for the system addon and failed in the probe. It was corrected to use the package's published `/flock` export and exercise the actual native operation; no production change was needed.

Two focused Python anchor/install tests and two Swift anchor/acquisition tests passed. The earlier uncertainty-admission verification remains recorded separately. No full regression suite was run. Existing AppKit concurrency warnings remain in unchanged code.

## Packaging, installation and restart

The rc.2 sidecar was installed and verified alongside the retained rc.1 version at:

`/Users/yingzhang/Library/Application Support/Safarier/DSHRuntime/53fad47a4ffc8cd0a8e9989ae619d1cfbe34618f7c9d921f52086ae4c5e01a9a`

The existing seven-stage unified release pipeline completed successfully. Build attempt:

`.build/automation-bound-control-integration-20261104/formal-test-app-20261106-001/packaging/attempt-20261116-112052-a186c2601fcd44adb9ec806677155605`

The candidate was installed at `/Users/yingzhang/Applications/Safarier AI.app` and copied to `dist/releases/Safarier AI.app`. Independent main-agent checks confirmed **150** source entries matched before/after packaging and current source; all **12** pins, strict signatures, metadata and namespace checks passed for both copies. Sidecar delivery directory: `dist/releases/unified-testing-20261116-032145-e9c75cae8967407588f902d41aec8ab4`.

Before installation the two browser helpers and Manager accepted normal quit requests. An old control daemon's normal stop returned `SESSION_BUSY`; after Manager and browsers exited, that exact daemon was terminated with SIGTERM for package replacement. This is not claimed as a successful control-release receipt. Session snapshots and the existing DSH user data were backed up before replacing the App.

The installed Manager was restarted. Read-only authorization returned `allowed`, with `businessEventSent:false`. The two previously running environments were restored through their existing launch paths: My through the ordinary interactive Runner, preserving its disabled Agent access, and 新媒体运营 through Manager. Both helpers and Manager were confirmed running from the installed bundle. Saved session counts matched the quit snapshots: My one window / seven tabs; 新媒体运营 one window / two tabs. No new search, page input or takeover was issued during this package acceptance.

## Recovery and evidence

- Previous installed App: `/Users/yingzhang/Applications/.safarier-install-backup-6b045af5f6094089a27eba569774c662.noindex/previous.app`.
- Previous fixed release: `dist/releases/.unified-release-backup-20261116-032145-e9c75cae8967407588f902d41aec8ab4.noindex/previous`.
- Evidence: `.build/dsh-rc2-upgrade-20261116/`, including official registry/release metadata, source review, runtime smoke result, focused test logs, source/package verification, session snapshots and `dsh-user-data-backup/`. User-data backups and raw process evidence remain private; access-bearing URLs and credentials are not reproduced here.

Changes remain uncommitted. The installed App includes both the registered preparation optimization and removal of persistent uncertainty admission blocks. These packaging checks do not replace the earlier live-control observations or establish that every possible takeover failure is resolved.
