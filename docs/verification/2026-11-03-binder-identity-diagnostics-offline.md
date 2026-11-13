# Binder 身份 BI_CHANGED 最小诊断离线进度（2026-11-03）

## 范围、状态和门禁

本轮仅在 `.build/automation-binder-diagnostics-20261103/worker/` 暂存诊断修订与离线测试，复用原 collector、Control、Transport、七个 Core 源码及冻结的生命周期 `FullHarness.swift`；没有接入正式 `Sources`、Manager、RunnerMain、AppBundle 或窗口/Space，也不是完整 live Binder 或 GUI 验收。仓库基线 HEAD 为 `2f32d21248deaffd8c8c1152a39912aa46350c7e`。本报告将 **worker 与主 agent 独立运行结果分列、不混计**。

主 agent 已复核 C/Header/Bridge 及测试 shim、closed parser 源码，未发现身份判据放宽，复核记录为 `.build/automation-binder-diagnostics-20261103/main-code-review.json`；其新根独立编译和运行结果单列如下，不与 worker 结果混计。主 agent 仅接受 headless 观测诊断组件，未放行 GUI 或输入。本轮最终门禁及保全以 `.build/automation-binder-diagnostics-20261103/main-final-audit.json` 为准；本报告本身不放行任何门禁。

## 最小诊断及原有行为边界

旧 ABI wrapper 将空 diagnostic 传给与新诊断入口共用的同一内部 collector 实现；调用方可提供独立的可选 `BIDiagnostic`，没有新增第二套 verifier/backend，也不使用 global/TLS 残留状态。诊断仅在 `BI_CHANGED` 时可解释，不构成授权；旧 evidence 在失败时的契约不变。

记录仅包含闭合 stage、首次失败的原比较对应的安全字段类别 bitmask，以及从 `/` 起的 root-to-leaf depth（根为 0，最大 127，不适用时为 NA sentinel）。stat 失败标 unavailable，不读取未初始化结果；hash 长度未通过检查时不越界比较。Swift 的闭合 operation phase 用于区分原采集阶段；仍按原顺序检查剩余期限和取消，只在 `BI_CHANGED` 安全记录后抛出原 collector 错误。新增 `collector-diagnostic` 诊断行不输出路径、PID 属性值、原始 token、nonce、frame、hash 或比较前后属性值；旧 `FullHarness` 原有 own PID 输出及构建命令/源码路径仍按原行为保留。不新增 OS 采样，不因 HOME 变化删除 mtime/ctime 或放宽任何原判据。

## Worker 定向证据（不等同主独立结果）

| 范围 | worker 本轮结果及限制 |
| --- | --- |
| C 定向与旧回归 | normal、ASan/UBSan 分别通过 metadata、受控 replacement、synthetic 字段及旧 snapshot/process/static/peer 回归；旧 mutation 测试只为内部新增可空参数作适配后两种模式通过。未变化的旧/新公开 API 对照、等价变更 fixture 的旧 NULL/诊断路径均记录；失败输出哨兵、调用间清零和并发隔离另有定向测试。 |
| 真实 kernel headless 正常往返 | normal 3/3、Swift ASan 1/1，使用 staged collector/Bridge 和原控制链；不是 GUI。 |
| 生命周期限定调度 | `aftercancel`、`commit`、`blocked`、`peerexit`、`overlap` 各 **normal 1 轮**；worker 此轮没有给这些单项各运行 Swift ASan。 |
| 边界负例 | `role`、`localrole`、`no-proof` 各 normal 1 轮；预期拒绝/清理证据见独立日志，不能按业务成功计数。 |
| Swift checked 实际失败通路 | 单独 normal 1 轮、Swift ASan 1 轮。真实 C snapshot callback 对新私有 fixture 作 `chmod`，产生 `BI_CHANGED`，经原 private `checked` 输出 `operation=resource`、`stage=FSTAT`、含 MODE 的 fields 与有界 depth，并抛出原 `IdentityBridgeError.collector("resource", 4)`。这是**正确拒绝，非业务成功**。 |

checked probe 将冻结 Bridge 原源码作为 7,819 字节精确前缀拼接测试 extension；前缀 SHA-256 为 `5963497de277d4539925b0ed3c50d94d0879a903cc30859ff0b85bb5992de4c0`。test shim 在唯一 C translation unit 中包含该 staged collector 并调用原 `snapshot_impl`，不伪造返回、也不链接第二份 collector；normal 构建不含此 shim。外部 closed parser 对 stdout/stderr 只接受安全格式并验证原错误、字段和 depth。probe receipt、源码及 SHA 清单位于 `worker/checked-probe/`；构建、各项运行及冻结前后校验记录见其中日志。

受控同字节文件替换及祖先替换在本轮 fixture 上首先报告 **parent-fstat**，不能将其称为 leaf inode 首次失败；root-to-leaf 顺序及其他祖先比较没有被跳过。单字段 INO/hash、进程身份等 helper 差异标为 **synthetic**，不是实际 kernel token 攻击或 PID reuse 证明。历史 lifecycle `final4-overlap-asan-1.log` 的 peer `BI_CHANGED` 发生在目标调度前；当时没有字段级证据，HOME 条目只具时间相关性，其确切原因仍未知，不能由新 fixture 反推 HOME 是原因。

## 保留的失败和证据链

1. 旧构建尝试在 macOS `/bin/bash` 3.2 的 `set -u` 下展开空 `opts[@]` 失败；根因由主 agent 对照确认。attempt 2 以非空 `swiftc` 命令数组条件追加参数，保留 `set -euo pipefail`；原失败未覆盖。
2. 第一版 replacement 测试 oracle 只预期父目录 mtime/ctime，实际首次比较 mask 还包含 size/nlink，因此断言失败；新命名测试按完整已捕获 stat 差异计算预期，原测试及失败日志保留。身份结果本来即为正确的 `BI_CHANGED`，没有为换绿放宽比较。
3. phase1 归档首次校验因重建计划文本多一个换行失败，失败记录保留；修正归档重建后旧 `STAGED-SHA256SUMS`、`PARTIAL-SHA256SUMS` 在对应归档目录通过，同期 main-feedback 清单另有校验。不能称所有历史尝试均通过。

worker 交接索引：`worker/attempt2-receipt.json`、`worker/attempt2-commands.md`、`worker/attempt2-SHA256SUMS`、`worker/phase1-archive/`、`worker/checked-probe/receipt.json` 及其清单。最初接口 RED 是旧头文件缺诊断 API 的编译失败，**不是**行为级 mutation RED；不可把它或后续成功覆盖原始失败。

## 主 agent 新根独立编译与验证（单列，不覆盖 worker 结果）

`main-review/independent-results.json` 共 **35 次程序运行断言满足**，不是 35 项 GUI 能力或业务成功：

| 独立验证范围 | 运行及结果 |
| --- | --- |
| C 定向与旧回归 | 16 次：metadata、replacement、synthetic、适配的旧 mutation 及旧 snapshot/process/static/peer，各 normal 与 ASan/UBSan 1 次，断言满足。 |
| 真实 Swift Bridge checked 负例 | normal 与 Swift ASan 各 1 次，实际 stderr 均为 `operation=resource`、stage 3、fields 528、depth 5，捕获原错误 `collector(resource,4)`。probe 程序退出 0 只表示拒绝及日志断言满足，**不是业务成功**。 |
| 真实 headless | 17 次：正常对照 normal 3 次、Swift ASan 1 次；`aftercancel`、`commit`、`blocked`、`peerexit`、`overlap` 各 normal 1 次及 Swift ASan 1 次；`role`、`localrole`、`noproof` 各 normal 1 次。正常会话退出 0；生命周期拒绝按预期退出 78，不计为业务成功。 |

35 次运行各自的 HOME metadata 记录均无变化；headless pre/post receipt 与源码记录一致，无意外 `BI_CHANGED`。证据分别为 `main-review/independent-results.json`、`headless-pre-receipt.json`、`headless-post-receipt.json` 与 `independent-sources.json`。这些独立结果不能抹除先前 worker 的失败，也不能确定历史失败的比较原因。

主 agent 的辅助静态和 ABI 检查另行记录：

- `core-preservation-check.json` 中 13 个关键安全/等价 helper 的归一函数体一致；5 个 collector 主体移除纯诊断部分及内部调用改名后与旧主体一致；原/staged OS 与 Security 源码调用序列各 32 项且次序一致。这是辅助静态检查，**不是形式化等价、全部条件控制流或时序证明**。
- `header-abi-check.json` 记录旧 8 个函数原型、已有类型及当前 SDK/架构的 size/offset 一致，不扩展为跨平台 ABI 保证。`collector-analysis.json` 的 C analyzer 退出 0、诊断数 0，不等于无缺陷证明。
- `no-gui-input-single-collector-audit.json` 记录 normal 直接依赖、未定义符号与源码扫描未命中所列 GUI/input/permission/listener 禁止项；normal 无 test hook 或 checked-probe shim，normal/probe 各有一个 `bi_snapshot`，probe 有一个 shim。该扫描**未穷尽传递依赖**。

## 不覆盖的安全与产品能力

本轮不证明 LOCAL peer 的逐消息不可变身份、主动 FD 转交、恶意同 UID 调试、原子 fd-exec 或瞬态 TOCTOU 防护，也不证明阻塞 OS 调用可由期限中断或完成 AppBundle 资源绑定。未执行真实 App/GUI、人工授权或全局输入，不创建 listener/helper；未更改系统授权/TCC、正常 App 权限、已有签名或安装，仅新私有测试夹具的 POSIX metadata/mode 按负例设计变更。**fullP1、GUI、manual grant、ready、armed、G1、G5、input、shipping、liveAdapter 均为 false**；主 agent 仅接受 headless 诊断观测组件，最终门禁以 `.build/automation-binder-diagnostics-20261103/main-final-audit.json` 为准。
