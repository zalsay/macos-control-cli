# Control 文档代际和释放：定向验证记录

本次针对页面自主导航导致旧 frame 可用、加载期间输入误关会话、释放期间页面跳转，以及业务权限查询无界等待进行源码修复。旧版协议不带 `expectedViewVersion` 的请求仍可解码；control broker 对基于 frame 的请求携带截图版本，Runner 在现有会话入口校验。

本机使用 `SAFARIER_CONTROL_TESTING`、`SAFARIER_BOUND_LOCAL_CANDIDATE`、`SAFARIER_INTERNAL_TEST_APP` 条件编译，仅运行下列过滤用例：

- `AutomationSessionTests/testSessionCases`：代际同步、旧版本拒绝、in-flight 不更新、导航忙碌后恢复和重试、协议新旧请求及重放身份。
- `ControlDocumentVersionTests/testOldFrameTextIsRejectedAndNewObserveRecovers`：broker 将 frame 版本传给文本和按键，旧 frame 拒绝、新截图可继续。
- `RunnerAutomationServiceTests/testDocumentChangeKeepsSessionAndRejectsStaleInputs`：模拟截图过程中文档变化、旧文本及按键被拒绝、输入投递后页面变化与直接释放。
- `RunnerAutomationServiceTests/testLoadingRejectionIsRecoverable`：模拟加载中 click/type/navigate 返回 busy，后续 state 和两阶段 release 成功。
- `RunnerAutomationServiceTests/testReleaseAfterDocumentChangesDuringPermission`：模拟 release 最终权限检查期间页面版本变化后完成 release。
- `ControlBusinessPermissionTimeoutTests/testStalledPermissionQueryReturnsTimeoutWithoutWaitingForNativeCall`：模拟权限查询晚返回，验证本地等待超时。

以上分别记录于忽略目录 `.build/control-review-20261116/terra-session.log`、`terra-broker.log`、`terra-service.log`、`terra-release.log`、`terra-permission.log`。机器代际回滚与权限等待用例均观察过修复前的预期失败；当时的失败输出位于会话工具记录，并未另存日志。曾误按类名运行 `RunnerAutomationServiceTests`，该类的旧 `testCases` 因缺少可信 fixture 在 open 阶段失败，不能视作通过。

上述测试使用 fake page / fake sender 或模拟权限查询，**不是实际 WebKit / TCC 端到端验收**。仍需隔离环境验证：加载中截图跨 document commit、页面自身跳转、由输入触发的跳转、截图异步竞争，以及 release prepare 和 commit 间真实页面跳转。本轮未安装新包或重启现有用户 App、浏览器和 daemon。

## 主 Agent 复核

主 Agent 独立审查生产代码及测试差异，重点复核请求版本的编解码与重放身份、输入前拒绝与投递后跳转的区别、加载中截图跨 commit 的失效、release 入场及准备阶段的版本处理、权限查询晚返回不发送业务事件。复核反馈由 Terra 修正后，最终运行以下合并定向验证：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  -Xswiftc -DSAFARIER_BOUND_LOCAL_CANDIDATE \
  -Xswiftc -DSAFARIER_INTERNAL_TEST_APP \
  -Xswiftc -DSAFARIER_CONTROL_TESTING \
  -Xcc -DSAFARIER_BOUND_LOCAL_CANDIDATE \
  -Xcc -DSAFARIER_CONTROL_TESTING \
  --filter 'AutomationSessionTests/testSessionCases|ControlDocumentVersionTests|ControlBusinessPermissionTimeoutTests|RunnerAutomationServiceTests/testLoadingRejectionIsRecoverable|RunnerAutomationServiceTests/testDocumentChangeKeepsSessionAndRejectsStaleInputs|RunnerAutomationServiceTests/testReleaseAfterDocumentChangesDuringPermission|NavigationSubmissionTests|InternalNavigationPolicyTests|RegisteredLoadSameDocumentTests|RegisteredSameDocumentTests'
```

最终编译成功；22 项测试通过（Core 3、App 19），无失败或跳过，未运行全量回归。日志：`.build/control-review-20261116/main-final-tests.log`。现有未改动代码的 Swift 并发警告仍存在。`git diff --check` 通过。该结果不扩大上文所述的真实浏览器验收范围；未提交或推送。
