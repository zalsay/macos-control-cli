# 多步骤 control 问题：源码修复与定向验证

基线为 `2026-11-16-browser-multistep-errors.md`；其原始记录保留。本轮修改针对 A、B、D 和 E，C 的包资源清单问题另行处理。

- A：对注册页面中由原生点击触发、来自绑定主 frame 的无请求体普通 GET 新窗口链接，在原决策取消后使用同一 WebView 提交原请求一次；等待导航继续使用既有 permit 和 correlation。其他普通新窗口请求取消，不打开额外标签。`InternalNavigationPolicyTests/testSameTabBlankLinkRequiresOrdinaryBodylessGETFromOwnedMainFrame` 在改动前失败、之后通过，日志为 `blank-red.log`、`blank-green.log`。这是策略级测试；实际 WebKit 回调时序、普通 click 的异步触发及课程链接仍未验收，不能视为目标课程已打开。取消后重新提交可能改变新窗口相关的 opener / referrer 语义，需实际验证。
- B：原始统一日志 `.build/control-multistep-fix-20261116/group3-unified.ndjson` 中，请求 `D234FD3C` 在纽约时间 06:38:09.200944 的 Runner sink 返回成功，09.360991 handler 返回成功，09.728101 回执入队；Manager 的 09.870552 lease budget available、09.870618 自动清理请求在 09.870748 将同一点击判为 `INDETERMINATE_RESULT`，而 endpoint 的成功回执至 10.448148 才返回。Manager 现有自动清理确实与已执行点击的回执竞争。源码在已有生命周期与清理预留内，对新动作检查完整可用预算，预算不足时完成 `SESSION_EXPIRED` 回执且不发送；已缓存结果及 request ID 冲突仍按原重放协议处理。注册页面显式 navigate 预留20秒，原生等待导航按既有 idle/cleanup 截止推导为54秒，普通动作10秒。定向记录 `budget-red.log`、`budget-final.log` 和 `budget-release-green.log` 覆盖请求预算、已缓存回执、同 ID 冲突、等待导航、提前醒来的清理与可完成的两阶段释放；使用 fake endpoint / 测试自有进程，并非真实浏览器验收。
- D：Runner pageFactory 的确定性 `INTERACTION_REQUIRED` 原被转换成 `BACKEND_UNAVAILABLE`，现直接透传，前台拒绝策略不变。`admission-red.log`、`admission-green.log` 记录单方法修前失败与修后通过；尚未真实前台连接验收。
- E：原 launch 客户端 PID 80003 的完整请求日志 `.build/control-multistep-fix-20261116/launch-request.ndjson` 中，`7BB7E3C8-7126-45EA-8996-2AD8026E7164` 最后停在 06:33:52.064396 的 `sender.native.permission.before`，直至客户端被终止前无 `permission.after`、`send.before` 或 Manager 收到请求的记录。该客户端卡在权限查询且未发送 launch 业务事件；浏览器已存在不能证明由此请求启动。此前已实现的业务权限查询有界等待覆盖此路径，本轮未新增 launch 超时机制；真实系统卡死场景未重新制造。

所有测试日志均在 `.build/control-multistep-fix-20261116/`。本轮未安装或重启用户 App、浏览器或 daemon，未重放外部搜索或课程点击；真实站点操作与打包后验收另行进行。

## 主 Agent 复核

主 Agent 独立审查了上述改动及 C 项的 BinderIdentity / BundleInventory 改动。复核中修正了旧 idle deadline 造成的误拒绝、等待导航 60 秒与提前清理的冲突、预算门禁遮蔽缓存回执的问题，并将 endpoint 超时改为 Manager 总截止的剩余时间。保留原始 90 秒绝对生命周期；预算不足的请求在发送前明确拒绝，释放不受该动作预算门禁限制，未将不确定结果伪装成成功。

最终独立验证为 25 项定向 Swift 测试全部通过（Core 2 项、App 23 项），日志 `main-targeted-tests.log`；另三条 C fixture 脚本全部通过，详见 `2026-11-16-bundle-ancestor-race.md`。未运行全量回归。Swift 命令如下：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  -Xswiftc -DSAFARIER_MANAGER_ROUTING_TESTS \
  -Xswiftc -DSAFARIER_CONTROL_TESTING \
  -Xswiftc -DSAFARIER_BOUND_LOCAL_CANDIDATE \
  -Xswiftc -DSAFARIER_INTERNAL_TEST_APP \
  -Xcc -DSAFARIER_CONTROL_TESTING \
  -Xcc -DSAFARIER_BOUND_LOCAL_CANDIDATE \
  --filter 'InternalNavigationPolicyTests|RunnerAutomationServiceTests/testOpeningPreservesInteractionRequired|RegisteredAutomaticCloseTests/test(WaitingNavigationCanBeAdmittedWithinRenewedIdleLease|InsufficientLifetimeRejectsBeforeInputAndStillForwardsRelease|EarlySchedulerReturnCancelsInFlightWithoutReplaying|AutomaticDeadlineObtainsBorrowedReceipt)|RegisteredManagerRoutingTests/testBudgetRejectionPreservesActualRelease|ControlBusinessPermissionTimeoutTests|ControlDocumentVersionTests|NavigationSubmissionTests|RegisteredLoadSameDocumentTests|RegisteredSameDocumentTests'
```

C 项已确定性复现并修复祖先目录的同级变化误报，但历史组 6 的具体变化源仍未证实。A 的真实 WebKit/站点验收、C 的安装后校验开销及 E 的真实 TCC 挂起恢复仍没有运行时通过证据。
