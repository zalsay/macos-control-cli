# 控制请求失败后的恢复修复

本轮范围为已注册浏览器的只读请求超时、释放阶段的可恢复拒绝，以及独立 DSH sfa 插件的失败连接清理。保留之前未提交的 Manager PSN 寻址修复；未打包、安装、重启 App 或重载 DSH。

## 原因和修改

- 插件把失败 connect 留下的 runtime 当作已连接状态，挡住 launch，又因 connection 为空挡住 release。launch 现在独立执行；无 connection 的 release 只尝试 daemon stop，返回真实 stop 结果。成功清理也能在历史恢复后识别。
- Runner 状态机原来把单次只读请求超时升级为整个会话停止。现在只结束该调用，保留其 timeout 回执；迟到 sink 结果不能完成后续请求。到期与新请求、权限撤销同时发生时，原请求的完成事件不会吞掉新请求或撤销事件。
- 原生客户端原来在任何已尝试请求超时后关闭通道，且把截图错误标为可能有页面副作用。现在完整发送后的已注册只读请求仅结束调用者，复用原 Pending 核验和消费迟到回包。没有另建错误锁或重放队列。关联回包早于发送协程返回时，也保持一致的核验期限。
- Manager 只读请求外层超时不再自动关闭会话。释放准备/提交明确拒绝为无副作用的 SESSION_BUSY/INVALID_POINTER_STATE 时，保留失败回执并允许新的显式释放请求。已准备阶段使用原 transferID 继续提交。真实原生失败、未确认的交还和实际通道故障仍走原清理路径。

## 定向验证

失败证据在 `.build/request-interception-review-20261117/`：

- `core-red.log`：修复前，观察超时与准备/提交 busy 会关闭会话。
- `manager-red.log`：修复前，Manager 把已知 busy 改成 indeterminate，随后阻挡读取或释放重试。
- `client-red.log`：原始客户端把截图超时标为 INDETERMINATE_RESULT/possible 并关闭通道。
- `client-race-red.log`：回包早于发送协程返回时，核验期限不一致会误关通道。

客户端专项命令：`python3 scripts/test-control-read-recovery.py`。该 fixture 编译生产客户端原样的 request/send/receive 方法；替换启动组合、签名/通道边界，并手动交付回包。覆盖超时、取消、核验期间到期、早到回包、超时后的真实协议交还、未知 requestID、错误回包类型、旧 fixture 路径、原生输入超时。它不是已安装 App 或真实浏览器的端到端验收。

Swift 定向测试使用 `SAFARIER_BOUND_LOCAL_CANDIDATE`、`SAFARIER_INTERNAL_TEST_APP`、`SAFARIER_CONTROL_TESTING`、`SAFARIER_MANAGER_ROUTING_TESTS` 构建标记，仅选择：

```
RegisteredRequestRecoveryTests
RegisteredReadRecoveryTests
RegisteredManagerRecoveryTests
RegisteredReleaseDeadlineTests
RegisteredReleaseBudgetTests
RegisteredExecutionChecksTests
```

插件仅运行失败 connect/start、历史恢复、未完整释放回执与 stop 重试相关用例。没有运行全量回归，没有对用户页面重复发送输入或导航。

最终结果：Swift 22 项通过（Core 11、App 11），客户端 fixture 9 个场景通过，插件 7 项通过。日志分别为 `final-swift.log`、`final-client.log`、`final-plugin.log`。本轮代码差异由主 agent 复核；`git diff --check` 通过。
