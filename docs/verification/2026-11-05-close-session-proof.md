# closeSession 真实清理证明验证

日期：2026-11-05（Asia/Shanghai）。范围是独立 local-candidate、固定本地 fixture、原同一 Binder／AppleScript／native 链；不是产品发布验收。

## 原缺口与真实证明路径

原 `AutomationManager.startClose` 仅调用 `closeAndWait` 并固定返回 `cleaned=false`，没有接收 Runner 页面／store 清理证明。修复仅对首次已认证的显式 closeSession／cancel，经同一 owned endpoint 的原 reserved request／channel 获取 Runner `sessionClosed`；真实 `cleaned` 来自 `page.destroy()` 与 `snapshotStore.close().cleaned` 均为 true。Manager 先核对 request ID、session token、target、原 owned tuple、codec canonical round-trip 及 wire `terminatedOwnedRunner=false`，再接受 proof，随后执行原 `closeAndWait`；最终 owned exit bit 仅来自原 retained owner 的 ProcessExit，不能制造 cleanup proof。

proof 使用普通 worker 额度并由原 entry 跟踪，退出清理保留原 cleanup worker 额度。一个原 **2 秒绝对 deadline** 覆盖 RPC 与退出观察，迟到 proof 不能升级已缓存结果；错误、未知或所有权改变保守处理。自动 fault／deinit／撤权等非显式关闭不自动发送业务 RPC。原 identity、lease、host `cleaned` 断言与 3 秒／45 秒边界均未放宽。

## 定向测试与早期真实运行

8 项 focused Manager case 与 21 项原 Manager 域检查 exit 0，验证 reducer／proof／退出等有限行为；**不等于真实 Binder 或 GUI 验收**。原首轮 `close-proof-001` 完整 smoke exit 0；其后 `close-proof-002` 在 close 发送前的 client mint／sendRequest 失败，Manager 返回 `cleaned=false`，整体 exit 1。Runner 在 channel EOF／serve 返回之后出现的清理日志，不能当作 Manager 收到且验证过的 proof。

## 时钟数值问题与修复

本机使用实际 `FrameDeadline` 的纯时钟 RED 中，2000 个样本有 **1956** 个 `DispatchTime(uptimeNanoseconds: raw).uptimeNanoseconds` 回读高于 raw，最大 **41 ns**；caller 原期限未变，但 roundtrip 后的待授权 cutoff 被向上扩大，原 strict `cutoff <= Pending.deadline` 门禁因此正确拒绝 mint；修复 factory 保留 raw，而非放宽门禁。该回归证明本机数值现象，并非部署系统全部源码逐字匹配证明。[Swift 官方 libdispatch `Time.swift`](https://github.com/swiftlang/swift-corelibs-libdispatch/blob/main/src/swift/Time.swift) 的 `DispatchTime(uptimeNanoseconds:)` 文档说明部分平台按 Mach timebase 向上舍入。

Core 改用 checked raw UInt64 cutoff helper，将六处数值 authority 直接保持为 raw；timer 仍使用 DispatchTime。原 `cutoff <= Pending.deadline` 检查、Runner 3 秒、45 秒寿命、Manager cleanup 2 秒，以及 `FrameDeadline` 原 init／remaining／run 均保留。纯时钟 GREEN 为 2000 个 raw 样本和 5 项边界断言通过，不是 Binder 身份证明。

## 最终原链两次新 session

| 证据 | close-cutoff-001 | close-cutoff-002 |
| --- | --- | --- |
| proof elapsed／accepted | 863 ms／true | 900 ms／true |
| wire receipt | cleaned=true，terminatedOwnedRunner=false | cleaned=true，terminatedOwnedRunner=false |
| Runner page／store | destroyed=true，storeCleaned=true | destroyed=true，storeCleaned=true |
| snapshot 清理 | 删除 1、保留 0、目录移除 | 删除 1、保留 0、目录移除 |
| Manager 最终 receipt | cleaned=true，terminatedOwnedRunner=true | cleaned=true，terminatedOwnedRunner=true |
| 原完整 fixture smoke | exit 0／smoke_complete | exit 0／smoke_complete |

两次均实际通过原 capabilities／open／state／hover／截图／drag／close 小链；pointer sequence 1–5，buttons **0、0、1、1、0**。原同 BID 唯一接收端、原 owned Binder、false permission preflight、真实 mouse ACK 与 host cleaned 断言保持；Host 持有的原 Manager 两次均已观察退出 status 15；Runner 退出由 `terminatedOwnedRunner=true` 单独观察，未记录其 status 为 15。固定候选和新 workspace／ephemeral profile 不改变正常 App／真实 Profile。

这里的完整链指既有 smoke 动作与门禁；可见效果核对的是 hover 截图，drag 仅按原生回执和按钮状态验证，未声明 DOM 拖拽效果或完整 G5 验收。

这是**本地 candidate 固定 fixture 的闭环证据**，不证明任意 URL、键盘、人工并发键鼠长期不受干扰、完整 G1／G5、shipping 或发布验收。所有旧候选、root、失败记录和日志保留。

## 证据

- 原 Manager 源审及 focused／原域检查：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/close-proof-20261105/main-source-review-001.json`、`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/close-proof-20261105/worker-core/green-001/`
- 原首次成功／重复失败的主 Agent 复核：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/close-proof-20261105/main-runtime-review-001.json`、`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/close-proof-20261105/main-runtime-review-002.json`
- 真实 FrameDeadline RED／GREEN 与最终源码复核：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/close-proof-20261105/worker-core/frame-cutoff-real-seal-red-001/`、`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/close-proof-20261105/worker-core/frame-cutoff-fix-001/`、`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/close-proof-20261105/main-source-review-002.json`
- 最终候选源码／产物及首轮主 Agent 复核：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/close-proof-20261105/main-cutoff-artifact-review-001/result.json`、`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/close-proof-20261105/main-cutoff-runtime-review-001.json`、`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/close-proof-20261105/main-cutoff-runtime-review-002.json`
- 最终两轮外层日志：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/close-proof-20261105/cutoff-runtime-001/run-001/`、`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/close-proof-20261105/cutoff-runtime-001/run-002/`
- 最终两轮 Manager／Runner 日志与 PNG：`/Users/yingzhang/safarier-bound-control-closecutoff-20261105-ec81a2168b814862854f5837586d76f5/close-cutoff-001/`、`/Users/yingzhang/safarier-bound-control-closecutoff-20261105-ec81a2168b814862854f5837586d76f5/close-cutoff-002/`；旧两轮：`/Users/yingzhang/safarier-bound-control-closeproof-20261105-e5e03bcd094442e19025f109c64b0861/close-proof-001/`、`/Users/yingzhang/safarier-bound-control-closeproof-20261105-e5e03bcd094442e19025f109c64b0861/close-proof-002/`。
