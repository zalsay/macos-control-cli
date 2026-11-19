# Safarier DSH rc.2 source build (macOS arm64)

Upstream: [DeepSeek Harness `dsh-v0.2.2-rc.2`](https://github.com/deepseek-ai/deepseek-harness/releases/tag/dsh-v0.2.2-rc.2), commit `ddac96760b6edf8fa0fe17cbdcf0b512f4c12b2c`. This is a locally built sidecar, not a repackaging of the npm DSH CLI.

- Installed upstream build dependencies using pnpm 11.28.5 and the frozen upstream lockfile. The upstream official build profile passed 8 tasks; the two aggregate build checks passed.
- Packed the DSH, vendor and system-addon families from build outputs. Assembled the CLI install from 336 local tarballs (including the DSH CLI and the macOS arm64 system addon); the npm lockfile records their local resolutions and the fetched external dependencies. The package lock and source assembly helper are retained under `.build/dsh-source-verification/`.
- Used the official macOS arm64 Node 24.19.0 binary. Its digest and Apple code-signing Team ID match the existing Safarier pins.
- The isolated CLI returned `0.2.2-rc.2`. Its Web service listened on loopback, returned HTTP 401 to an anonymous request, and exited 0 on shutdown. Koffi loaded, sharp generated a PNG, the arm64 system addon acquired a file lock, and node-pty spawned a process successfully.

Neither the isolation tests nor the package build requires live Safarier data, model credentials, or a running browser. They do not establish authenticated chat or model connectivity.

Artifact: `dist/releases/2026-11-19-dsh-rc2-source/runtime-artifact`. The offline verifier rechecked the independently measured hashes and compared the read-only mounted image against the canonical inventory (101,383 entries, including 13 symlinks). The Node pin is unchanged.

- Image SHA-256: `0f29271d5109a558f5b72eca5b54e5eac101b3253bcb0a5d94fd8b7642ef9f47`
- Manifest SHA-256: `6302ccf5f9e3dc649f11a231f691ea61166bf6cdabbedf29a31526ad152e7082`

The Swift loader and Python installer pin those exact digests. The 11 focused installer tests passed. An isolated install and Swift loader probe verified acquisition, launched the mounted CLI (returned `0.2.2-rc.2`) and detached the image successfully. The baseline full Python suite had one pre-existing failure, `test_real_process_inside_target_is_detected`, before this pin update.

The ad-hoc-signed Safarier testing App and matching sidecar are staged together at `dist/releases/2026-11-19-dsh-rc2-source/testing`. The 152 build input digests matched before, after and against current sources; the App signature and offline Host protocol smoke passed. Packaging verified the source and copied App and runtime. The live installation was not replaced or restarted.
