# DSH runtime review artifact

Create an unreviewed image from explicit absolute paths, with a new output directory:

```sh
python3 scripts/dsh-runtime/prepare.py --dsh /absolute/dsh --node /absolute/node --output /absolute/new-review-dir
```

Independently verify an artifact by passing both SHA-256 values from the reviewer-controlled record, never by copying values from `review.json`:

```sh
python3 scripts/dsh-runtime/verify.py --artifact /absolute/review-dir --manifest-sha256 <reviewed-manifest-sha256> --image-sha256 <reviewed-image-sha256>
```

The Python API is `verify.verify_artifact(artifact, ExpectedHashes(manifest_sha256, image_sha256))` and returns `VerificationResult` with the artifact path and counted entries. A future runtime worker may use this as its offline evidence boundary; it does not expose a Node path, child process, mount lease, install operation, or sidecar location.

The verifier requires exactly `manifest.json`, `runtime.dmg`, and `review.json` in the artifact namespace; the latter is ignored as a trust source. It opens and copies the manifest and image into its own private temporary directory, checks each against the explicit expected digest, mounts only that private image copy read-only, and compares the complete mounted namespace, types, modes, symlink targets and file hashes to the pinned canonical manifest. A path replacement after copying cannot change the verifier's private copy. Concurrent replacement during acquisition fails the descriptor/path consistency checks or the explicit digest checks. The verifier rehashes the private image after unmount. It detaches only the mount it created and removes only its private temporary directory. A detach failure preserves that directory for diagnosis.

Artifact path components must be directories and cannot be symlinks; on macOS only the standard root-owned `/tmp -> private/tmp` and `/var -> private/var` system aliases are accepted and then checked through their canonical targets. This allows root-owned `/`, `/Users` and other normal ancestors without requiring the user to own them. Each artifact file must be a regular single-link file owned by the current user, with no group/other write access or special mode bits. These checks do not pin every ancestor against concurrent same-user replacement and do not constitute runtime protection.

This is point-in-time offline artifact verification. It does not establish a trusted installation, production binding, runtime lease, or protection from later replacement of the artifact or backing image. It does not close same-user races after verification or prove what a later process will execute.

The offline installer has explicit commands:

```sh
python3 scripts/dsh-runtime/install.py install --artifact /absolute/review-dir --versions-root /absolute/existing-private-dir
python3 scripts/dsh-runtime/install.py verify --version-dir /absolute/existing-private-dir/<image-sha256>
```

`install.install_reviewed(artifact, versions_root)` and `install.verify_installed(version_dir)` provide the same offline Python interfaces, not production integration. `versions_root` must already be an absolute, owner-only (0700) directory owned by the current user; the component does not create an application data directory. Installation verifies the source, copies into a new private staging directory, verifies the copy and publishes it with macOS `RENAME_EXCL` under the image SHA-256. Existing or concurrently published versions are never overwritten and are reused only after full verification. Both interfaces use the source-level `install.REVIEWED_ANCHOR` for the independently reviewed candidate; runtime upgrades require a new review and source edit of the `RuntimeAnchor` containing manifest SHA-256, image SHA-256 and Node version. They never derive an anchor from `review.json`, argv or the environment. Tests patch an anchor only inside isolated fixtures.

Node version in that source anchor records the reviewer's finding; this tool does not execute Node and cannot itself establish the version or native module compatibility. Reviewers must verify those against the Node bytes included in the pinned manifest/image before approving the source edit.

The intended future user-private sidecar path is `~/Library/Application Support/Safarier/DSHRuntime/`, but this tool does not select, create, or access it. DSH_HOME and agents are separate writable user data, not part of this image or installer. This component provides a startup-time integrity check, not protection against a malicious process running as the same user throughout execution; mount lifetime, Node execution and subsequent module loading remain the responsibility of a separately reviewed runtime integration. No privileged installation, app identity binding, or automatic fallback to global DSH is implemented here.

The tool does not execute either input. It copies them into a private temporary tree as `dsh/` and `node/node`, inventories paths, types, modes, sizes, file SHA-256 and relative symlink targets, then creates an HFSX UDZO image. It mounts that image read-only at its own temporary mountpoint, compares the complete mounted inventory to `manifest.json`, and detaches it before publishing output. `review.json` records manifest, image and Node hashes as **unreviewed** values. The image hash need not be reproducible; the canonical manifest is deterministic for identical trees. An `INCOMPLETE` marker indicates unsuccessful output publication. Failed attach/detach may retain the named private temporary directory for manual investigation; do not delete a mounted directory.

These are build-review artifacts, not a trusted installation or runtime verifier. The DSH wrapper is copied unchanged and may search for external Node; this tool does not select or launch it. The caller must independently assess the Node signature, architecture, dynamic dependencies, DSH native module compatibility, and the complete manifest and image before approving any compiled pin. The inventory rejects group/other write permissions, special mode bits, hard-linked files, special objects, and symlinks that leave the tree even temporarily, dangle, or cycle.

A read-only mount prevents writes through that mount, but does not by itself protect the backing image against replacement or modification, establish the identity of a later mount, or prevent same-user unmount/remount. This tool is not a race-resistant execution boundary against concurrent same-user mutation. No trust anchor, installed version, production service, or running process is changed.

## 统一 testing 构建、固定目录更新与安装

在 `/Volumes/RC500/dev/safarier` 运行：

```sh
python3 scripts/dsh-runtime/unified-release.py
```

进度条显示已完成的七个阶段和当前步骤，不代表耗时或文件处理百分比；终端中的长步骤会定期显示运行状态，重定向输出时保留简洁阶段记录。失败时显示出错步骤，不标记完成。

入口使用现有 release testing 构建及 `package-release.py`，复核受审 runtime 与 Swift 固定锚后生成配套目录，再更新 `dist/releases/Safarier AI.app`、`candidate-sha256.json` 和 `release-current.json`。新候选的 GUI 和 CLI 均待验收；候选自身的 pins 和 evidence 是一致性收据，不是独立信任锚。runtime 变化必须重新审核并更新相应源码锚；可用 `--artifact /绝对路径` 指定已审核材料，不能以其自带的 review.json 代替审核。

入口使用单写入锁，先校验完整候选并备份旧文件；普通失败尝试回滚。三个固定路径不是整体原子切换，更新期间读取可能看到中间态。其他写入者必须遵守该锁；此锁不能阻止不配合的并行修改。强退或回滚失败会留下 `dist/releases/.unified-transaction`，后续构建将停止：确认没有构建进程，按其中 `RECOVERY.txt` 检查备份、固定路径和 staging，恢复一致状态并核验后再手动移走事务目录。已成功更新的旧版本备份路径记录在 `release-current.json`。

固定目录更新成功后，入口会将固定候选复制到 `~/Applications` 中的私有暂存目录，复用现有双层签名、命名空间及全部候选 pins 检查，并在替换后重新校验安装包和固定包。两份包与配套候选使用相同 pins；pins 是一致性收据，不是独立信任锚。安装目录不存在时会创建，现有目录必须由当前用户拥有且不可由组或其他用户写入；不接受符号链接目标。脚本不会启动 App 或修改 DSH 用户数据。

运行前退出安装路径下的 App 和 Browser；**整个脚本运行期间不要启动或操作安装路径下的 App 或 Browser**。脚本在安装前和替换前通过进程列表检查该路径，发现运行中会停止；进程列表是时点观察，可能受系统可见性、路径表示和检查后启动的竞态影响，不能保证发现所有进程或阻止新启动。其他路径运行的 Manager 不会自动关闭：安装后请先退出它们，再从 `~/Applications/Safarier AI.app` 启动，避免唯一接收端路由冲突。

安装目录使用独立单写入锁；旧包保存在同目录 `.safarier-install-backup-*.noindex/previous.app`。普通失败尝试回滚，失败事务保留为 `.safarier-install-failed-*.noindex`；强退或回滚失败时保留 `.safarier-install-transaction`，后续安装会停止。确认构建及目标进程均已退出，按其中 `RECOVERY.txt` 检查目标、旧包和暂存包，恢复或校验后手动移走事务目录。锁只约束配合该流程的写入者；不提供对其他程序并发修改的保护。安装与固定目录更新是两个阶段，安装失败或中断时 release 可能已经更新，错误信息会指出这一点，须分别核对两个位置；不要假定它们一致。

这是本地 ad-hoc 签名、未公证的 testing 候选。sidecar 仍按配套 `INSTALL.txt` 独立处理，自动 App 安装不代表 sidecar 已安装或 GUI/CLI 验收通过。
