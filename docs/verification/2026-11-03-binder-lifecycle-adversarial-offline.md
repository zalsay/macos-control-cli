# Binder 认证控制通道生命周期对抗离线验证（2026-11-03）

## 范围和当前状态

本记录只覆盖 `.build/automation-binder-lifecycle-20261103/worker/` 中的 headless CLI、原匿名 socketpair、真实 kernel identity collector 与原有 channel/control 路径；**未接入正式 Sources、Tests、Package、Manager 或 RunnerMain，也不是真实 GUI Binder 验收**。worker 最终 staged `FullHarness.swift` SHA-256 为 `d0854ca3f70e4b3beeafa074e4253bbe68e05a59a01d5c9145ee1bdca6e18ca8`，仓库 HEAD 为 `2f32d21248deaffd8c8c1152a39912aa46350c7e`。记录的负例在真实 hello/proof/ack 及 identity 往返后进行；测试 flag 和调度 hook 不属于 normal build。

主 agent 对最终源码 normal 预处理行为的复核结论是：仅有下列两项预期行为变更，其他差异属于测试编译期调度或格式；证据为本轮 `main-review/normal-behavior-review.json` 与 `main-review/normal-behavior.diff`。主 agent 已对该最终源码完成独立编译、矩阵及两个冻结 RED 复现；结果单列于下节，不能冲销 worker 历史失败。主复核接受范围仅为 headless 生命周期实现及所列限定调度验证，复核记录为 `.build/automation-binder-lifecycle-20261103/main-code-review.json`；原失败缺少确定原因字段的问题仍未关闭。本轮最终保全以 `main-final-audit.json` 为准。

## 两个问题与 staged 最小修复

1. **取消继承至原 cleanup。** 在已认证 active 会话中取消 controller，原 catch 中的 `waitForExit` 与身份采集均检查当前 task 取消状态；实际 RED 记录原 cleanup `cleanup_unconfirmed`、未取得 fresh proof。RED 专用安全收尾在独立任务中继续持有原 owner、取得 fresh proof，并观察到受控终止 `status=15, signal=true`，不是自然退出。日志为 `worker/cancel-active-red-1.log`。staged 修复只将原 cleanup 放入单独保有并 await 的任务，仍使用原 owned handle、新鲜身份核对及原有等待，不凭 PID 扫描清理；后续最终源码测试中对应场景有 fresh proof、请求终止及 signal 15 的记录。独立清理有等待预算，但 OS collector 阻塞调用不能被该预算中断。
2. **post-validation 后、commit 前取消未被最终检查。** 在实际响应读完并完成 post-validation 后，测试 hook 在原 private commit 前暂停；先取消再释放时，旧版本 RED 显示 `firstRejected=false`，即该次操作仍返回成功。证据为 `worker/commit-red-diagnostic-commit-normal-1.log` 和冻结的 RED 源。staged 修复仅在原 private commit 增加 `Task.checkCancellation()`；最终源码的相同确定调度按取消拒绝并在非已取消外层验证后续调用为 closed。该检查是协作式边界，**不证明检查之后外部取消与 commit 原子化**，也不能倒推已提交成功的操作无效。

## Worker final4 九类测试及结果

以下每类均是在最终源码上固定安排的 normal 3 次；除 overlap 的 Swift ASan 1 次失败外，其余各类 Swift ASan 1 次均通过相应断言。原有 channel、parser、deadline、owned spawner 和 identity collector 继续使用；不把纯 gate 模型当成已连接事务。每类实际日志均在 `worker/final4-<名称>-<normal|asan>-<轮次>.log`，汇总为 `worker/final-receipt.json`。

| 名称 | 实际调度和断言边界 | worker normal | worker Swift ASan |
|---|---|---:|---:|
| `pre` | 双方 active、ping 已发送，目标操作进入前先取消；操作拒绝，非已取消外层再调用得到 closed。 | 3/3 | 1/1 |
| `aftercancel` | 实际 response 已由 channel 读出，在 post-validation 前 hook 暂停、取消；拒绝并保持 closed。 | 3/3 | 1/1 |
| `afterpoison` | 实际 response 已读、post-validation 前首操作仍持 gate 跨 await；第二操作进入并 poison，首操作和后续操作不能成功。 | 3/3 | 1/1 |
| `peerexit` | 实际 pong 已读且 post-validation 尚未开始；controller 对自有 socket 写半关闭，endpoint 观察原通道 EOF 后自然退出 0，owner 确认退出后释放 hook，post-validation 拒绝。不是 signal 15。 | 3/3 | 1/1 |
| `drain` | 完成 finished 后进入 `finishAndDrain`，在 `SHUT_WR` 后、drain read 前取消，后续调用 closed；**不是已阻塞 drain read 取消的证明**。 | 3/3 | 1/1 |
| `commit` | 真实 response read 和全部 post-validation 后、private commit 前取消，检查取消并拒绝后续使用。 | 3/3 | 1/1 |
| `overlap` | 双方 active 且 ping 已发；首 receive 在真实 pre-read 验证后持 gate 跨 hook await，第二操作 poison，首操作与后续调用被拒。该点不证明响应已经到达。 | 3/3 | **0/1，未到用例** |
| `cancel` | 双方 active、ping 已发，首 receive 在 pre-read hook 暂停时取消；在非已取消任务中验证 closed，并经原 owner/fresh proof 清理。 | 3/3 | 1/1 |
| `blocked` | endpoint 测试 flag 写入两字节不完整 frame header 并通过观察 pipe 通知；controller 对自有 socket 观察 FIONREAD 队列为 0、无 HUP/ERR、peer alive 且 receive task 尚未完成，证明这两字节已由原 channel read 消费而正在等待剩余 header，再取消并在非已取消外层验证 closed。 | 3/3 | 1/1 |

worker 最终源码的正常 finished 路径另有 normal 3/3；此处未将 C ASan 称为 Swift UBSan。测试负例的断言 PASS 代表按预期拒绝，controller 会话仍失败退出 78；它不是业务会话成功。peer 自然退出 0 与 fresh proof 后受控终止 signal 15 必须分别记录。

FIONREAD 是当前 Darwin SDK 的 `_IOR('f', 127, int)`；主 agent 独立 `_Static_assert` 与实际 SDK 宏相等并确认 `sizeof(int)==4`，见 `main-review/fionread-sdk-check.c` 和 `.log`（1074030207）。这只限定当前 SDK；normal build 不包含该测试观察，不推导其他 SDK/架构行为。

## 主 agent 独立复测与 baseline（单列，不覆盖 worker 失败）

主 agent 的 `main-review/independent-results.json` 记录 **44 次**预定运行，各次记录的断言均满足；这不表示这些会话均业务成功。九类生命周期用例各 normal 3 轮、Swift ASan 1 轮，正常对照另 normal 3 轮、Swift ASan 1 轮；旧 `NEG_ROLE` 与 `NEG_CLEANUP_NO_PROOF` 各 1 轮，冻结的 cleanup RED 和 commit RED 各 1 轮。两个 RED 的断言是**原失败现象得到复现**，并非问题被判为业务成功。正常对照退出 0；负例和 RED 的 controller 按预期退出 78。受控终止的 `status=15, signal=true`、peer 自然退出 0 和缺少 proof 时的 `cleanup_unconfirmed` 均按各自 marker 区分，不能互相替代。

独立矩阵的所有 root 和二进制在运行前预先准备，44 次会话记录的 HOME before/after 元数据均未变化；`main-review/independent-pre-run-receipt.json` 与 `independent-post-run-receipt.json` 字节一致。这是独立批次的观察，**不证明 worker 那次 `BI_CHANGED` 的原因**。独立复测 overlap ASan 满足断言，也不能消除或改写 worker final4 overlap ASan 的 0/1 认证失败。

本轮原有离线 suite 的 **69 checks baseline** 通过，证据为 `main-review/baseline-checks.json` 与 `main-review/baseline-model-suite.stdout`；69 不是本轮新增的 69 个测试，也不是上述 44 次矩阵运行的计数。主 agent 对最终 normal 二进制执行 `otool`/`nm` 和已编译源扫描：未发现受禁止的 GUI、input、permission 或 listener 直接依赖/符号及源码命中，normal `nm` 未发现 `ReadSchedule`、`CompletionObservation`、`_ioctl` 测试符号；详见 `main-review/no-gui-input-normal-build-audit.json`。该审计未穷尽全部传递依赖，不应扩大其结论。

## 保留的失败和限制

`worker/final4-overlap-asan-1.log` 在认证阶段 collector 返回 `status=4`（`BI_CHANGED`），尚未进入 overlap 测试点；不能记为该用例 ASan 通过。`worker/final4-overlap-asan-diagnostic.json` 记录该次日志存续区间内 HOME 下出现另一条目，这与祖先快照变化**可能相关但未证因**：现有证据无法确定具体哪个 collector 比较发生变化。保留原始失败、未以重试转绿；其他版本或后续主 agent 独立结果均不能抹除这一事实。

测试 hook 增加的 await 改变了调度，观察结论限于记录的边界；正常情况下已经完成 post-validation 后的 peer 退出不能倒推当时验证无效。LOCAL peer 是 socket last-owner/use 信息，不是逐消息不可变身份；不证明主动 FD 转交、恶意同 UID 调试/运行时篡改、原子 fd-exec 或瞬态 TOCTOU 安全，也不是完整 AppBundle 校验。测试 flag 构建保留 unreachable-code 编译警告；不放宽身份、期限或门禁。

完整源码差异、每轮日志、run-root/binary SHA 与证据清单分别见 `worker/FINAL-FullHarness.diff`、`worker/final-receipt.json` 和 `worker/FINAL-SHA256SUMS`；phase1 历史副本及 manifest 保留在 `worker/phase1/`。**full P1、GUI、manual grant、ready、armed、G1、G5、input、shipping、liveAdapter 全部为 false；没有从离线结果放行任何真实 GUI 或自动输入。**

本报告不代替 `.build/automation-binder-lifecycle-20261103/main-final-audit.json`。
