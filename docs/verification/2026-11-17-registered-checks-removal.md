# 已注册控制连接的重复校验移除

日期：2026-11-17。范围：已注册交互式浏览器的执行与 release 链路；未运行全量回归。

## 修改

- RunnerAutomationController：复用已绑定 target；删除每次命令初始、派发前、最终执行前的重复 permissionReader/targetReader 调用，以及 release/commit 执行后的再次读取。实际 sink 对页面对象、ticket 的检查和执行错误保留。
- AutomationManager：registered release 不再读取 profile；普通动作仍读取 Agent 开关并在关闭时拒绝派发。
- BrowserSession：注册服务初始授权读取前后仅检查本地 context 活性，不再重复全套 Binder 校验。
- AutomationRunnerServer：首次握手保留进程、peer、包资源和配置校验；成功认证的注册连接在请求/回执阶段复用绑定，只检查取消、撤销、期限、通道及已有 owner/client 状态。显式 profile/preparation 校验仍走完整路径。Runner 的 peerPinned 只在全部初始校验完成后发布。
- 原有非注册 fixture 路径保留。请求关联、重复执行保护、真实 input/store 清理、prepare/commit 交还回执均保留。

此前 release 分阶段预算修复继续保留，本次没有再次增加期限。

## 定向验证

构建参数：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  -Xswiftc -DSAFARIER_BOUND_LOCAL_CANDIDATE \
  -Xswiftc -DSAFARIER_INTERNAL_TEST_APP \
  -Xswiftc -DSAFARIER_MANAGER_ROUTING_TESTS \
  -Xcc -DSAFARIER_BOUND_LOCAL_CANDIDATE \
  --filter 'RegisteredExecutionChecksTests|RegisteredReleaseBudgetTests|RunnerAutomationControllerTests'
```

最终运行 7 个 XCTest，通过，无跳过：

- RegisteredExecutionChecksTests：3 个。已绑定输入和 release 两阶段不调用重复读取器；错误 session 不执行；重复请求只执行一次；实际 sink 错误原样返回。
- RegisteredReleaseBudgetTests：3 个。打开连接后配置不可读不妨碍 release；commit 失败不伪报成功；Agent 开关关闭时普通输入不转发。
- RunnerAutomationControllerTests：1 个聚合测试，验证保留的非注册授权、取消、清理和回放行为。修正其中过期的 5/2/30 秒硬编码，使用当前 action/held/cleanup/idle 期限；未修改生产期限来适配测试。

另外，本次生产代码修改后运行 RegisteredReleaseDeadlineTests，5 个通过，包括实际超过 10 秒的外层协调器测试。合计 12 个相关 XCTest 通过。

先运行新增用例确认失败再实现。日志：

- `.build/registered-checks-removal-20261117/red.log`：修改前重复读取导致预期失败。
- `.build/registered-checks-removal-20261117/green.log`：release deadline 的 5 个测试通过；旧 controller 聚合用例因过期计时断言失败。
- `.build/registered-checks-removal-20261117/final.log`：校正测试计时后 7 个测试全部通过。

主 agent 对照本轮修改前快照复核了四个生产文件的增量。`git diff --check` 通过。

## 验证边界

本轮只完成源码修改、编译和定向测试；没有重新打包/替换已安装 App，没有操作 Test 或其他用户浏览器。签名包中 Binder 通道的首次握手和运行期快速路径尚未进行本轮端到端验证。不能据此声称真实 release 耗时已降到某个数值，或原先现场 TIMEOUT 已通过新包复测。
