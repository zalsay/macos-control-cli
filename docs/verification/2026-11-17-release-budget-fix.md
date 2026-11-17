# 2026-11-17 release 超时排查与定向修复

## 证据与原因

沿用已安装候选 App 的 Test 实测失败记录，未重新操作用户浏览器：

- 主请求：`026B7A63-30D1-4A21-8006-B4B312F34599`。
- commit 子请求：`765D6C25-BBA2-44A3-99A1-64C3ACD70984`。
- 日志：`.build/google-multistep-execution-20261117/main/release-trace.log`。
- Runner 本机日志：`~/Library/Application Support/Safarier AI/logs/8D0DB3A8-F413-4C32-8685-FC769FC7669F.log`。

Manager prepare.before 至 prepare.after 为 7.917 秒，其中 Runner 真实输入释放和快照目录清理为 0.806 秒。外围包含请求传递、Binder/权限校验和回执传输。Controller 每阶段调用权限读取四次，每次读取前后各执行 Binder 验证；本轮未删除或缓存这些检查。

第二阶段开始时只剩 2.082 秒。commit 进入初始权限检查后，共用的 10 秒期限到达，外层协调器返回 TIMEOUT 并取消 Manager 工作。

源码存在四层相关预算：

1. `AutomationManager.release` 将等待在途输入、prepare、commit 和 owner/drain 交接全部放进一个 10 秒窗口。
2. `AutomationSessionMachine` 在 prepare 开始时设置 10 秒 `releaseDeadline`，commit 复用它。
3. `AutomationRequestCommand` 对 release 使用普通 action 的 10 秒协调器期限。
4. `ControlAppleEventClient` 对 release 使用普通 action 的 20 秒发送期限；仅修改 Manager 也可能被这里提前截断。

超时后 Runner 日志记录 `session.restore.after` 以及 `destroyed=true storeCleaned=true removedFiles=11 directoryRemoved=true`。说明本地恢复与清理路径执行完成；但 generation 通道已经关闭，Manager 没取得原会话的完整确认回执。后续 `CLEANUP_UNCONFIRMED` 不能解释成浏览器进程被关闭，也不能被改成释放成功。

## 修改

复用原有两阶段协议与计时器，不增加重试或替代执行路径：

- 已注册浏览器 Manager 总预算为 34 秒，来自等待在途输入 10 秒、prepare 10 秒、commit 10 秒、通道排空 4 秒。
- prepare/commit 的 endpoint 请求各自最多 10 秒，不让一个阶段占满整段组合预算。
- Runner 的已注册会话握手总期限为 20 秒，各自 flight 仍最多 10 秒；无人提交 commit 时仍会到期。
- AppleEvent 接收端通过共享 `AutomationAction.managerTimeoutSeconds` 使用组合期限；发送端使用它加 10 秒传输余量，release 为 44 秒。现有 C 发送上限 70 秒和 CLI 90 秒接收期限足够容纳。
- 普通输入操作期限未改变；非注册 fixture 的 Manager/Runner 释放期限仍保留原行为。
- 没有删除四项 release 证明、真实权限与身份检查，没有把取消/超时或清理未确认伪装为成功。

## 验证

本轮主 agent 实现并复核，未委托代码审查。保留仓库已有未提交修改，只修改上述预算路径、定向测试及说明文档。

`.build/release-budget-20261117/red.log` 证明修前：两次各 8 秒的正常阶段无法完成；Runner 在 commit 完成前进入 stopping。

`green.log`：9 项定向测试通过，无跳过，覆盖：

- prepare 8 秒、commit 8 秒、最终排空 3 秒，Manager 接受完整 release 回执。
- Runner 在 prepare 已耗时 8 秒后仍能完成第二阶段。
- prepare/commit 各自卡住仍在单次动作期限内结束。
- prepare 完成后没有 commit，握手仍有限期。
- commit 失败不返回成功释放。
- 在途输入排空、原有显式关闭和失败 drain 的确认边界。

`coordinator.log`：额外 1 项真实计时测试通过，协调器等待 11 秒后接收 release 成功回执，不再于第 10 秒提前取消。合计 **10 项**，没有运行全量回归。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  -Xswiftc -DSAFARIER_BOUND_LOCAL_CANDIDATE \
  -Xswiftc -DSAFARIER_INTERNAL_TEST_APP \
  -Xswiftc -DSAFARIER_MANAGER_ROUTING_TESTS \
  -Xcc -DSAFARIER_BOUND_LOCAL_CANDIDATE \
  --filter 'RegisteredReleaseDeadlineTests|RegisteredReleaseBudgetTests|RegisteredManagerRoutingTests/testReleaseWaitsForInFlightInputBeforeHandoff|RegisteredAutomaticCloseTests'
```

实际执行为上述筛选的前 9 项和新增协调器测试分别运行，原始日志均保留。Manager 测试使用注入 endpoint 与虚拟时钟；协调器测试使用真实 11 秒等待。它们不替代已安装 App 的签名 Binder、AppleEvent 与 Test 环境端到端释放验收。

本轮没有重新打包安装，也没有重启现有浏览器；安装包仍是修前版本。源码修复已通过定向验证，实际 App 释放需新包复测后确认。外围多次身份校验的性能开销仍存在，本轮修复的是两阶段协议与各层期限不匹配的问题。
