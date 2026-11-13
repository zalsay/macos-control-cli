# Binder Controller 离线对抗验证记录

- 日期：2026-11-04；作者：Terra worker；阶段：**offline staging only**。
- 工作基线：`mcc-safarier`，HEAD `2f32d21248deaffd8c8c1152a39912aa46350c7e`。
- 本记录汇总主 Agent 的独立审查及执行证据，不代表产品修复、生产接线、发布或 GUI 授权。

## 来源与范围

- 前一实现基线：`/Volumes/RC500/dev/safarier/.build/automation-binder-controller-impl-20261104/worker/attempt-052/src/`。
- 本轮统一候选：`/Volumes/RC500/dev/safarier/.build/automation-binder-controller-adversarial-20261104/worker/attempt-016/src/`；测试 driver：`/Volumes/RC500/dev/safarier/.build/automation-binder-controller-adversarial-20261104/worker/attempt-016/ControllerTask34Main.swift`。
- 主源码审查：`/Volumes/RC500/dev/safarier/.build/automation-binder-controller-adversarial-20261104/main-review/main-code-review-source.json`；driver 审查：`/Volumes/RC500/dev/safarier/.build/automation-binder-controller-adversarial-20261104/main-review/main-code-review-driver016.json`。
- 主汇总：`/Volumes/RC500/dev/safarier/.build/automation-binder-controller-adversarial-20261104/main-review/final-matrix-summary.json`。该汇总及各 `results.json` 保存运行结果、冻结输入及证据路径；各运行目录保存实际命令、环境、输出、退出码与镜像 SHA。
- 基线 052 到候选 016 的 30 个源文件中，仅 `AutomationChannel.swift`、`AutomationRunnerClient.swift` 不同：限 TEST_ONLY 观察、调度与 512/12 降容。原 C、KernelIdentityBridge、provider、ProfileLock、OwnedRunnerProcess 和 V1 保持不变；未更改生产默认路径或接线。
- 主套件实际编译 `attempt-015/src`；主汇总确认其 30 个文件与 `attempt-016/src` SHA 相同。统一新 driver 016 已由主实际重新构建并执行；015 与 016 的历史执行不可混称。

## 主独立执行矩阵

| 项目 | CLI 程序数 |
|---|---:|
| 主独立对抗 driver | 12 |
| 主重编译并执行 worker 新 driver 016 | 28 |
| no-hooks 原路径 | 2 |
| Controller 1 / 2 / 34 | 24 / 16 / 24 |
| Runner 回归 | 74 |
| 两轮额外 fresh-fixture 回合 | 28 |
| **合计** | **208：normal 104，ASan 104** |

上述 208 均符合各自预期 oracle；四项无 hook API 的负向编译结构检查另列，不计入 208，也不是行为 RED。矩阵为有界离线 CLI 证据，不代表完整 P1、GUI 或产品验收。

## 压力、预留位与顺序

- 512 变体通过实际三个已占用帧的 **484 字节**和目标帧真实编码 **166 字节**证明 `484 + 166 > 512`；走原 reserve 算术和真实 C/opaque admission，不注入错误、计数或伪时钟。
- 健康压力返回 `sessionBusy`、sideEffects `none`；目标未入队/未写，预算回零；同一 ID 可重用，跨过已结算旧 admission 的实际截止后同连接仍可用。
- 先出现一次 busy、再取消/超时/关闭另一个已排队请求的测试，与**同一真实 backpressure catch 暂停后**对该受压目标 cancel/timeout/close 的测试分别记录；后者按原 attempted 控制请求保守返回 `indeterminateResult`、sideEffects `possible`，而非健康 busy。
- timeout oracle 先观察实际原 admission cutoff 和 monotonic，再检查结果时 cutoff 已到；没有伪造时间。`firstTerminal=nil` 仅表示该次观察未记录诊断，不能证明特定错误优先。
- 默认 ordinary/reserved pending 为 8+2，send 为 2+2，字节预算 `4 × (65536 + 4) = 262160`，sent-ID frontier 4096，均未改。正常 API 最多 2+2 个发送在途，四个最大有效帧也不超过该预算，因此不通过增加 payload 上限或并发来制造压力。512 和 12 仅是 lower-only 变体上的真实路径试验，**不是默认 262160 满量或 4096 次实跑**。
- 实际 enqueue/completed frame ID 用于比较原 writeQueue FIFO 与完整写出；主用例先观察两个 ordinary 实际入队，再等两个 control 实际入队后释放 head。control 只优先于后续尚未入队的 ordinary，不抢占 head 或重排任何已入队帧。异步 handler 顺序不是 wire 顺序。
- 具体独立结果：`/Volumes/RC500/dev/safarier/.build/automation-binder-controller-adversarial-20261104/main-review/main-adversarial-summary-final015v3.json`；driver 矩阵见 `/Volumes/RC500/dev/safarier/.build/automation-binder-controller-adversarial-20261104/main-review/worker-unified-final016-pressure/results.json`。

## 同代与跨代边界

- 不同 profile、预建两把 lock 的并发 case 中，接收方拒绝原 owner 的真实未 claim admission 且只关闭接收方；原 owner 可继续。来源：`/Volumes/RC500/dev/safarier/.build/automation-binder-controller-adversarial-20261104/main-review/main-adversarial-final015v3-default/results.json`。
- 同 profile 顺序代际中，先确认 A 原 owner 退出，再启动 B；同 ID 的 B pending 不受 A 旧 callback 释放影响。实际 A generation 与实际 A reply 在 B 的具体 validator 被拒绝；B 也拒绝 A 的真实旧 opaque token。
- 上述是具体 callback、上下文 validator 和 token/API 的证据。V1 没有逐帧 wire generation nonce：新可信 peer 重发与新合法响应字节完全相同的内容不可区分；不能将其描述为逐帧密码学跨代防重放保证。

## 失败记录与保全边界

- 主 V2 pressure：8 pass、1 fail。其测试误判实际帧之和会超过 512；失败路径虽等待原 owner，wait 返回未打印，因此**不是 owner 已退出证明**。V3 使用真实帧字节算术与明确 wait 日志；旧失败不计入最终 208。`/Volumes/RC500/dev/safarier/.build/automation-binder-controller-adversarial-20261104/main-review/main-v2-pressure-oracle-failure.json`
- 主方统一重编译执行的 worker 015 driver：21 pass、1 fail；ASan 下请求 timeout 2 秒与原 Runner idle 2 秒竞跑，实际为 `runnerExited` / none，Runner endpoint status 1、handlers 0。016 仅缩短测试 timeout 并增加实际 cutoff oracle；这是测试竞态修正，不是原产品 bug，旧失败不计入 208。`/Volumes/RC500/dev/safarier/.build/automation-binder-controller-adversarial-20261104/main-review/worker015-timeout-oracle-race.json`
- worker 013 的 Swift Task 泛型推断编译错误与日志保留；它是结构性编译失败，不是行为 RED。`/Volumes/RC500/dev/safarier/.build/automation-binder-controller-adversarial-20261104/worker/attempt-013/swiftc.stderr`
- 历史 tmp-glob/refusal workaround、只读 process scan、compiler cache 73 文件事件维持原有未解决记录；新绿测不使其消失或证明已修复。
- 写本文前主 byte audit：324 个 project 文件、14217 个选定旧文件、5 个选定安装/candidate/fence 文件、9 个旧 candidate 文件均按清单字节未变；branch/head、保存的 index 与 sibling 状态未变。证据：`/Volumes/RC500/dev/safarier/.build/automation-binder-controller-adversarial-20261104/main-review/preservation-before-doc.json`。
- 该审计仅覆盖所列范围。文档写入后的最终保全与验收结果分别以 `/Volumes/RC500/dev/safarier/.build/automation-binder-controller-adversarial-20261104/main-review/final-preservation-audit.json` 和 `/Volumes/RC500/dev/safarier/.build/automation-binder-controller-adversarial-20261104/main-final-audit.json` 为准，写文前审计不替代该最终检查。

## 门禁、未覆盖范围与下一步

`fullP1`、`G1`、`G5`、`input`、`shipping`、`liveAdapter`、`GUIExecutionAuthorized`、`manualGrant`、`GUIReady`、`ready`、`armed` 全为 **false**；这些是策略门禁，不是对 OS 权限数据库状态的判断。`productionComposition` 仍 unavailable。wire ready 仅用于关联，不是 GUI 许可。

未执行真实 GUI/NSApplication/WebKit、AppleEvents/System Events、global input、LaunchServices、Keychain、TCC、VM、完整 App build/XCTest、真实 profiles、安装写入或 commit/push。不能据此声称系统 quiescence、无孤儿、无泄漏，或文件系统/进程/peer/物理写之间全局原子性；也不证明真实 OS EINTR 或停滞中断。Controller 侧压力试验不证明 Runner 端压力分支；完整 45 秒自然寿命未测。

下一步仅可先准备接入前的组合设计、独立验证与门禁清单，并交由主 Agent 和用户决定后续授权；本记录不授权自行生产接线或开启 GUI。
