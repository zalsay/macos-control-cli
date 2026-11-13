# Binder 的 AppBundle 资源与进程生命周期：离线设计

日期：2026-11-03；分支 `mcc-safarier`；基线 HEAD `2f32d21248deaffd8c8c1152a39912aa46350c7e`。本轮在 `.build/automation-binder-bundle-20261103/worker/` 隔离实现真实磁盘 Bundle 清单与无头进程生命周期绑定；未接入产品 `Sources`、Manager 或 RunnerMain。主 agent 为唯一设计/源码审查及独立验收者。`.build/automation-binder-bundle-20261103/main-code-review.json` 记录主 agent 已接受有界离线 Bundle + 进程生命周期源码及 53 次独立程序验证（Task 1 的 24 次和 Task 2/3 的 29 次分列）。最终保全门禁以 `.build/automation-binder-bundle-20261103/main-final-audit.json` 为准，本设计不替代 audit。

## 1. 授权和不证明的范围

只处理 reviewed 本地 AppBundle 的磁盘内容/实例、真实 headless 同映像进程与原有认证连接。真实 AppKit application/window、LaunchServices 注册、Space、profile、人工 foreground/grant、GUI 生命周期、路由和用户输入共存均未实现或验证；不构造虚假的 GGContext token，也不调用 `gg_manual_begin`、`gg_seal`、`gg_arm`。`fullP1`、G1、G5、input、shipping、liveAdapter、GUIReady、ready、armed、GUIExecutionAuthorized 和人工 grant 均保持 false。离线验证不构成 GUI 阶段授权、产品集成、部署或发布。

EntryCandidate.app 仅可只读静态检查，永不执行或重签；其原 `/Volumes/RC500` 路径因 775 祖先仍不满足旧安全策略，不放宽权限。经 EUID 拥有的 0700 HOME 根制作私有副本后，可以对照既有 baseline 静态验证，副本也不执行。独立的 tiny C CLI 或 Swift headless CLI fixture 可以在新建 0700 根内构造期作一次本地 ad-hoc 签名，BID 为 `sh.safarier.offline.bundlebinder`；Swift 链接器可能已附 ad-hoc，构造期可对该 fresh-root 白名单内从未 pin/运行的 fixture 使用 `--force -s -`。先完成打包和签名，记录根 dev/ino、命令及签后 SHA，再 pin；不重签已 pin 的 fixture、旧根、候选、正常 App 或系统资产，不通过修改后重签消除负例。仅直接执行 fixture 的 `Contents/MacOS/BinderProbe`，不通过 open、NSWorkspace 或 LaunchServices。

## 2. 现有功能复用和绑定边界

- 原 diagnostic `BinderIdentity.c/.h` 提供 `bi_snapshot` 文件 SHA/metadata、`bi_static_pin` 静态映像、`bi_process_metadata`、`bi_capture_self` 与 `bi_capture_peer`；复用其安全祖先策略、动态 code、audit guest、PID/PPID、UID、birth、path、前后采样与 BI_CHANGED stage/mask 诊断，不新增第二套 peer verifier 或进程执行器。
- `BundleInventory.c/.h` 是补齐目录 inventory 与整个 Bundle Security 检查的必要辅助层；`bb_inventory` 返回的 opaque 观测不是授权。fixture 的完整路径/类型预期写在 staged 源码常量；candidate 对照既有 baseline 的 **16 个目录/文件条目和 9 个文件 SHA**。初始未知空目录、文件或 `.DS_Store` 也拒绝，不能先发现一棵树再将其自身作为预期。
- 私有 `BundleResourcePin` 构造先用 `bb_expect_exact` 对照独立预期，再用 `bb_revalidate` 在完整前后清单比对之间验证 strict seal、plist 和主映像 pin。fixture 的主映像 SHA 不预嵌入自身；由受控新签 fixture 的原静态 image pin 与实际 kernel self/peer code 绑定。静态 resource pin 单独不是进程绑定授权；staged `KernelIdentityBridge` 在该过程前后实际采集 self 并比较，连接绑定再核对 peer 与原 owner/实际 parent。预期不由 argv、环境、wire、nonce 或当前发现的值选择。
- Bundle 位置从 kernel 返回的 self 可执行路径严格推导为 `.app/Contents/MacOS/BinderProbe`，不沿用旧 `bin/resources/fixture` fallback；动态进程的 main path 必须等于该实际路径。candidate 的静态 inspector 本身在 Bundle 外运行，不得为验证 candidate 而运行其可执行文件。
- 直接复用原 `Control.swift`、`Transport.swift` 和七个 Core 文件：`AutomationChannel`、`AutomationProtocol`、`AutomationHandshake`、`OwnedRunnerProcess`、`RunnerLauncher`、`RunnerLaunchSpec`、`SPIFeatures`。沿用原匿名 socketpair、parser、role、presence、hello/proof/ack、identity/ping/finish、half-close 和原 `FoundationProcessSpawner`；不叠加新 transport、executor、listener 或运行时 helper。

## 3. 全量目录、metadata 与签名

目录根和祖先按原 root/EUID 所有且非组/其他可写策略，以目录 FD、`openat` 和 no-follow 遍历。包括所有目录、空目录和常规文件；仅跳过 `readdir` 自带的 `.`/`..`，拒绝外部 traversal、符号链接、文件硬链接、特殊文件、控制字符、路径歧义及不支持布局；目录正常 nlink 不作为硬链接误拒。当前实现保守支持 ASCII 成员名，不声明所有 Unicode 文件名可用。目录流从已持 FD 用 `openat(fd,".",O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)` 独立打开，避免 dup 共享 offset；每次 `readdir` 前清 errno、空返回立即检查，管理 `fdopendir` 接管和失败关闭。对根与各成员进行路径映射、stat、snapshot 与前后复核。

边界为最多 256 条、相对深度 16、单文件 64 MiB、文件内容合计 128 MiB；metadata 中 xattr 名称/值与 ACL 合计每次 Bundle inventory 不超过 4 MiB，Info.plist 的解析读取不超过 1 MiB。metadata list/get/hash/ACL 操作沿用调用方的原绝对期限并在操作前后检查；超时返回 expired，不刷新期限。超限、不可读取或不支持时 fail closed，不省略属性。受检实例记录包括根及成员 dev/ino、uid/gid、mode、nlink、size、mtime/ctime/birthtime、flags，以及 xattr/ACL digest；各文件内容使用原 collector 的 `bi_snapshot`。

稳定 content digest 带版本域分离，按相对路径字节排序，长度前缀编码路径、类型、文件长度与文件 SHA，包含空目录；它不含 inode、UID 或时间。instance pin 则保留独立的根/成员身份和 metadata，重验比较两者及完整成员集合。Info.plist 解析对象必须来自自身 SHA、长度和 metadata 与 snapshot 匹配的同一份 bytes，检查 `CFBundlePackageType=APPL`、独立 BID 和精确 executable leaf。

`SecStaticCodeCheckValidity` 针对整个 `.app` 使用 SDK 的 `kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate`，不使用跳过资源、跳过 executable 或 basic-only 标志；签名 identifier 与独立 BID、主 code unique 与 `bi_static_pin` 一致，且前后完整清单与实例均一致才接受。签名只证明受控制品一致性，不证明公证、Developer ID、Hardened Runtime 或公共开发者信任。系统 Security 调用可能阻塞；时限可拒绝迟到结果，不保证中断 OS 调用，也不宣称原子全盘快照、FD-exec 或消除瞬态 TOCTOU。

## 4. 生命周期与清理

staged `AuthenticatedConnection` 内部保存 `unbound → bound(private generation) → revoked`，仅在 Bundle、self 及真实 peer/owner 或 actual-parent 核验成功后绑定一次；generation 只是私有生命周期标签，不是信任根或可序列化授权。controller 的 cleanup 权仅来自原 retained `OwnedRunnerProcess`；endpoint 观察到的实际 parent 不获得清理权。事务前后重验 Bundle、self、peer 与 owner/parent；跨 await 后和提交前检查同一 generation、原 gate、取消与剩余期限。资源/进程变化、重复绑定、旧 generation、取消、退出、超时或迟到结果均 sticky revoke/abort/close，不能隐式恢复；正常 finish 保持原 half-close/EOF。

失败清理与资源许可分离：仅原 owner 在独立有界 detached cleanup 中等待退出；仍运行时，使用新鲜 `bi_process_metadata` 对照原 PID/PPID/UID/birth/path 和 retained handle，再请求 TERM。Bundle seal 已失效或 lease 已撤销不阻断纯 metadata 采集。缺证明则 `cleanup_unconfirmed`，不对 observed parent 或扫描到的 PID 发信号。保留原 3 秒 frame/45 秒 lifetime，转换剩余时间给 C monotonic deadline；不得延长或缓存跳过检查。

## 5. 证据边界

实现、source SHA、diff、worker 运行与独立结果索引见 `docs/verification/2026-11-03-binder-bundle-lifecycle-offline.md`。最终 worker 日志只输出实际比较后的布尔阶段，不逐帧输出 kernel UID、birth、path 或完整 code hash；先前详细调试日志原样保留且单列。主 Task 1 的 24 次与 Task 2/3 的 29 次是分开记录的程序运行，不都是业务成功；主源码审查已接受有界离线范围，最终保全门禁以本轮 `main-final-audit.json` 为准，本设计不替代 audit。FD 转交、恶意同 UID、阻塞 OS 调用与真实 GUI 用户输入共存仍在本层证明之外。
