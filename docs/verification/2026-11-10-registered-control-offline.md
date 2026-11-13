# Registered control 离线验证（2026-11-10）

本文前半记录离线验证与候选打包；随后经用户授权安装并由独立 worker 进行 GUI 实测，最新失败记录见文末。不是正式发布或真实注册 GUI 验收通过。

- Core/Manager 修正：仅从原 Core client 或具体 registered wrapper 解包真实 client，保留原身份/唯一实例/capabilities roundtrip 校验；sessionClosed codec 编解码拒绝 retainedBrowser 与 cleaned/terminatedOwnedRunner=true 的矛盾组合。
- 11 项定向测试通过：RegistrationDescriptorTransferTests 5、PersistentBindingTests 2、RegisteredBorrowedReceiptTests 3、RegisteredManagerRoutingTests 1。最后一项使用显式 SAFARIER_MANAGER_ROUTING_TESTS 注入 seam，仅证明 fake orchestration 的 release/重连/旧 token 拒绝，不证明真实签名注册。
- Anscombe 最终离线验证 12 项通过（Core 3、App 9），日志：`.build/registered-page-worker-build/validation-final.log`。覆盖 repository 代理/订阅绑定、multiplex、borrowed receipt/drain、V1 release reply 后客户端 EOF 返回 0、首次 loading 等待/冲突/超时、navigation watchdog。该组与上面 11 项存在重叠，不合计为 23 个独立用例。V1 EOF 是离线通道验证，非 signed Binder 实测。
- 页侧保存原启动 actual RunnerPreparationPlan，在接管前以 context.validate(profile:)/validate(preparation:) 校验原 profile/代理/订阅；首次页面加载等待不刷新已有页，新建无 startURL 的受控页使用真实 about:blank。上述实现边界与 watchdog/drain 配套，真实网页及 signed Binder 仍须 GUI 验收。
- candidate 宏编译通过；证据：`.build/persistent-control-baseline-2ejdSX9j/review-resume-20261110/focused-final.log`、`candidate-build.log`、`result.json`。测试命令与准确边界见该 result.json。

打包命令：`python3 scripts/bound-control-candidate/build.py --variant testing --configuration release`，退出码 0，未带 SAFARIER_MANAGER_ROUTING_TESTS。

- Stage：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/formal-test-app-20261106-001/packaging/attempt-20261110-083843-aec667e2ce0944c3bc006a2a0ee44818`
- App：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/formal-test-app-20261106-001/packaging/attempt-20261110-083843-aec667e2ce0944c3bc006a2a0ee44818/Safarier.app`
- Pin receipt：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/formal-test-app-20261106-001/packaging/attempt-20261110-083843-aec667e2ce0944c3bc006a2a0ee44818/candidate-sha256.json`（11 项）
- 源库存：stage 的 source-before.json/source-after.json；121 项 before=after=current（构建后读取核对）。文档不属于 source_inventory。
- 精确 Swift 命令和 codesign 输出：stage 的 `commands/`。主独立复核已完成：11 pins、两层 strict 签名、source inventory、namespace、metadata、resources、help 全部通过。原记录为上述 stage 的 `main-review-receipt.json`；归档副本为 `dist/releases/2026-11-10-arm64-default-cli-control/main-review-receipt.json`。
- 外层命令/退出码/日志：`/Volumes/RC500/dev/safarier/.build/registered-release-71111fbadc8041e4b7fd332b0a873c8b`。

原打包时 GUI 待验（最新同窗口重连结果见文末）：真实注册后 release→同窗口新代重连，cancel/断连/过期时窗口及 persistent cookie/localStorage 保留，旧身份与跨 profile 拒绝。V1 release→EOF 返回 0 已有上述离线证明，但原打包时真实 signed Binder 的 status==0/重连仍待验；最新同窗口重连结果见文末，不代表 g2 release 已成功。首次 loading 等待已有离线测试，最终 prepare 拒绝后 root 的恢复不能声称已通过 GUI 验收。followProxy exec 后真实接管尚未验证：hello/ready wire 不比较语言/时区，Runner 本地仍须以实际参数和保存的启动 plan 校验 profile/代理/订阅。不得将 fake 测试替代这些证明。

## Startup-fix GUI 失败：已确认焦点回归

startup-fix 包已主独立核验并获用户授权安装；安装记录：`.build/default-cli-startup-install-b8e337adb54b4dd684beaaacbd6492ea/install-receipt.json`。这不代表 GUI 验收通过。

本轮原始证据：`.build/sf-persistent-gui-e292d7ca0b524beaaadc9ec7d012711f/evidence/`。Runner/page 打开成功，finish_opening 后 share query 触发 block（主核对 Runner 日志）；connect 失败/结果未知，未重试。`immediate-report.json` 与 `observer.jsonl` 末帧记录 Runner active=true；用户随后明确确认窗口自行抢前台。**此包存在已确认焦点回归，GUI 未验收，不能声称非干扰通过。** 用户确认补充于原始 summary 的 userInterferenceNotDetermined 之后，原始证据不改写。

原报告 target/connection/cleanupReceipt 均无证明，不能将页面打开或进程状态替代成功连接、释放或清理。参考 `summary.json`、`immediate-report.json`、`runner-log-increment`、`steps.json`。此结论仅针对本轮，不追溯改写此前独立时段用户反馈。

后续 NonActivatingBrowserWindow、accessory 可恢复控制租约及 share 纯查询修复由 Anscombe 独占生产源码；本次仅更新文档，不构建、替换包或操作 GUI，修复结果仍须独立验证。

## Focus-fix GUI 部分结果（资源已收尾，release 未确认）

focus-fix 包已主独立复核并安装，记录分别见 `dist/releases/2026-11-10-arm64-default-cli-control-focus-fix/main-review-receipt.json`、`.build/default-cli-focus-install-67cd0cccc9dd41ccaac838b5b7d154ae/install-receipt.json`。以下不改写早期 startup-fix 焦点回归或原始失败回执。

首轮证据根：`.build/sf-persistent-gui-cffcea7b055c4ecdb1f4f0526a7b7a32/evidence/`。

- `g1-connect.stdout`、`g1-state.stdout`、`g1-observe.png` 已证明连接、state 和 PNG 成功；OCR unavailable，不能计为 OCR/JEV 输入成功。
- `safe-failure-disconnect.stdout` 的 retainedBrowser 四项 inputReleased/artifactsCleaned/browserRetained/manualInteractionEnabled 均 true，target 与原连接精确匹配；cleaned=false、terminatedOwnedRunner=false，无页面销毁/Runner 终止宣称。artifact 已删除；`retained-proofs.json`、`summary.json` 留有原回执，首轮 daemon 已停止、socket 不存在。
- 2026-11-10 01:12:47–01:13:05 UTC 本轮前台采样为 Antigravity；33 个采样实际覆盖 01:12:47.465–01:13:04.627，未见 Manager/Runner active（`focus-and-retention.json`、`readonly-status-after-ocr.json`、`observer.jsonl`）。用户最新明确反馈本轮没有干扰，补充原 summary 的未确认状态；采样非连续证明，反馈不推广至其他时段，也不抵消早期焦点失败。

同窗口重连证据：上述根下 `reconnect-8c4fd1168936470b9a965cbf89bfb378/`。`g2-connect.stdout`、`g2-state.stdout`、`g2-target.json` 已证明 g2 连接/state 成功，profile/runnerInstance/window/page 四项 target 与 g1 完全相同。

`g2-navigate-check` 因剩余预算不足未发送；`budget-stop-release.stdout` 返回 TIMEOUT；`terminal-readonly-status.json` 于 2026-11-10 01:20:07.554447 UTC 确认无成功 release/cleanup 回执、daemon/fixture 仍运行且 socket 存在，Runner 日志为 `root_closed result=unconfirmed`。后续 `stopOwnedDaemon-disposal.json` 与 `stopFixture-disposal.json` 记录 01:20:52 UTC 经原 Popen 对象发送正常终止信号，两者 exit=-15、cleanupProof=false。此操作仅属测试 daemon/fixture 资源收尾，不是认证 daemon stop 或 release 成功证明；未操作 Manager/Runner，窗口保留。release 真实成功仍未确认，root_closed unconfirmed；**不计 release 成功或该代清理已确认**，不以本地日志或进程状态代替协议证明。当前只证明上述部分结果；persistent cookie/localStorage 跨代往返、实际输入/导航、其余取消/过期/身份拒绝及手动接续等未覆盖边界仍保留。定位尚未完成，不作根因判断；服务退出不替代成功 release 回执。不重试未知操作，不改写原始记录。


## Release-diagnostics 单轮 GUI：prepare/commit 返回，owner 转移未确认

本节为后续新增证据，不改写前述失败、部分成功或待验项目。固定路径 `/Users/yingzhang/Applications/Safarier.app` 本轮为 release-diagnostics 包；主独立核验 11 pins 与两层 strict 签名后授权执行。receipt：`dist/releases/2026-11-10-arm64-default-cli-control-release-diagnostics/main-review-receipt.json`，SHA256 `d0e7203c2f0e59715f9ae23b71ef6aa428da6a6f4a81810f478c6d612f19f5fa`。

证据目录：`.build/sf-release-diag-gui-5b8fed44ab024d46b5af34066e928e6a/evidence/`；外层起止记录在其上级 `execution.json`。本轮 UTC 2026-11-10 01:42:24.395468–01:42:37.008013，fresh 单 profile 的普通 launch 仅打开合成 loopback `/check`，OSLog/observer 前置；无 seed、state、OCR、额外导航或鼠标键盘输入。connect 用时 4.059633s，返回后 0.000198s 即发 release，无上一轮人工调度等待。

- release requestID：`3ECE8BEB-3219-4579-8AD3-A9208F535CD3`；关联 commit requestID：`F935C730-E915-4E02-9A31-93FD78CE618C`。`release.stdout` 为 `status:error / TIMEOUT`，不是客户端 subprocess timeout；release 用时 5.595588s。
- `release-oslog.jsonl` / `release-correlation.json`：prepare.before 单调时间 4726604ms，prepare.after 4727647ms，约 1.043s；commit.after 与 takeOwner.before 均 4728566ms，commit 约 0.919s。进入 takeOwner 时剩余约 3.037s，至 4731755ms 记录 `manager.failed.after.takeOwner.before`；coordinator 随后记录 `TIMEOUT:TIMEOUT`。没有 takeOwner.after。该轮排除“测试等待耗尽 45s”解释；仅这些 trace 尚不能单独区分 Core owner 调用与 registered.confirmDrained。
- 未取得最终 controlReleased/retainedBrowser 四项证明，target 未返回，不推测四 UUID。prepare/commit 的内部返回不等于对外 release 成功。`confirmedEndings` 仍为空，**release/清理未确认**。
- `observer-summary.json`：21 个采样，01:42:25.788–01:42:36.747 UTC，Manager/Runner active 样本均为 false，前台样本为 Codex；最后可见 Runner 窗口 1280×852。采样不替代用户无干扰确认，也不证明人工接续可用。未追加截图/OCR影响本轮时序。
- `owned-daemon-disposal.json`：daemon 由持有 Popen 发一次 TERM，exit=-15、cleanupProven=false；外层 `execution.json` 记录 fixture 同样 exit=-15、fixtureDisposalCleanupProof=false。两者仅属失败测试进程处置，不是认证 daemon stop 或页面清理证明；socket 留存，证据与 workspace 数据未删。Manager/Runner 窗口保留，未知操作未重试。

## Owner 转移递归根因、最小修复及离线边界

上述 owner 调用链的源码追查及独立跨模块 Swift 复现确认：App `AutomationManagerEndpoint` 定义 async `takeReleasedOwner(matching:)` 默认实现；Core `AutomationRunnerClient` 原本有同名同步 actor 方法。App 默认实现与 registered wrapper 中的 `await client.takeReleasedOwner(matching:)` 在该 async 上下文选择协议 async 默认实现，再次进入自身，而非 Core 同步 actor 方法。因此原 Core owner 验证/转移和 channel.close 未被执行，也未到 registered.confirmDrained；Runner 后续 `server.read_failure TIMEOUT`、`root_closed unconfirmed` 见 `runner-final-diagnostic-excerpt.txt`。这不是 prepare/store 慢或需要放宽 deadline 的证据。

独立复现：`.build/release-diag-9f4705182b4c46ef9dc79a951d4f855e/dispatch-repro/`，用测试哨兵在第三次默认实现重入时截断；输出保存在 `.build/release-dispatch-fix-13ef71972c404f41ba5d6ec80a66543d/before-repro.log`。它验证语言分派根因，不冒充真实身份/清理证明。

最小生产修复为三处改名：Core 方法改为唯一名 `takeValidatedReleasedOwner(matching:)`，App 默认实现和 registered wrapper 两个调用点同步更新；另加一行防止恢复同名 overload 的说明。Core 原 `validatedRelease`、bound target、pending 为空、owner.isRunning 等全部 guard/body 保持不变；未调整 5s/45s、身份检查、清理证明或 root drained 条件。baseline、`minimal.patch` 和冻结源 hash 在 `.build/release-dispatch-fix-13ef71972c404f41ba5d6ec80a66543d/`；主已独立 review 此最小修复。

定向离线验证：

- `scripts/test-release-owner-dispatch.py` 编译实际 App 协议 adapter 和 registered wrapper，对接隔离 Core double，覆盖具体 client、协议默认实现、registered wrapper 三条调用路径：实际 Core double 恰好调用三次，registered drain 一次，重复转移被拒绝。`dispatch-test.log` 通过。此 double 不证明真实 Binder/窗口/存储清理。
- Candidate 宏编译成功；`final-build-test.log` 中 `AutomationScriptTests.testScriptCases` 1 test、0 failures，含既有 timeout/late completion once 边界。未把空 test suite 或此前因私有 fixture 缺失的 skip 算通过；原 diagnostics 阶段 2 个旧 Manager 断言失败、4 个 skip 保留在 `.build/release-diag-9f4705182b4c46ef9dc79a951d4f855e/test.log`，未为诊断修改旧断言或开门。

## 当前安装与 GUI 状态：仍 pending

按主提供的最新构建/审阅状态，修复 candidate 已打包并经主 review，归档为 `dist/releases/2026-11-10-arm64-default-cli-control-release-dispatch-fix/`；**尚未安装，也尚未运行修复后的 GUI**。固定路径仍为旧 release-diagnostics 包，不将候选打包/离线通过当作已安装或 release 验收通过。

安装受阻：主确认旧 Manager 46944 已不在运行（退出原因未确认），原测试 Runner 46967 的 PPID 已变为 1；严格旧停止脚本不再满足 parent 检查，因此没有据此终止 Runner 或覆盖固定包。主已请用户手动关闭 `SF persistent GUI test` 窗口，目前等待用户处理；worker 不重试关闭、不强杀、不以 PID 路由、不执行 GUI。

下一单轮目录 `.build/sf-release-diag-gui-61801b89fec54fe7804e59e46d47ed5d/` 只复制已审五个脚本（逐字一致），没有 prepared/evidence/execution 运行产物。仅待后续安装与明确 GO，再做同样 fresh connect→立即 release；不扩大矩阵。真实 release 成功、四项 proof、同窗口后续重连等未覆盖的原 pending 项仍为 pending。
