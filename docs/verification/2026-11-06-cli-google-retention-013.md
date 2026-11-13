# Safarier CLI Google 搜索与窗口保留：013 记录

状态：2026-11-06 实测证据。用户已确认完整窗口可手动继续浏览，且 013 测试期间操作其他 App 未发现干扰。此记录不代表发布或部署。

测试 App：`/Users/yingzhang/safarier-cli-retention-testing-b91dd9f55dbe402ab56ae6bf3ced2609/Safarier.app`；独立 workspace 为同目录 `workspace`，profile 为 ephemeral opt-in `7064e28f-c8f9-4f1a-8524-21cccc723793`。候选来自 `.build/automation-bound-control-integration-20261104/formal-test-app-20261106-001/packaging/attempt-20261106-192352-c332510c60c34c4085ab224cecf94cff`；109 源清单前后一致，副本九项 pin 匹配，主 agent 已审查 source/artifact/copy。测试 driver 为 `.build/cli-control-001/retention-gui-013/driver.py`，与已审 012 相同。App 源变更相对本轮前快照见 `.build/cli-control-001/retention-design-009/app-frozen-v3.diff`，此后 release 预算的 App 修正见 `.build/cli-control-001/retention-design-009/app-prepare-013-v2.diff`；Core/Manager 的独立修改及主审见对应冻结证据。

## 013 一轮结果

时间均为北京时间。19:25:35.262 发起 connect、19:25:40.180 完成；显式导航 `https://www.google.com/webhp?hl=en` 后，依据当次 initial screenshot 的焦点光标，原生输入 `AI` 一次并用 Enter 提交一次。19:26:04–08 的最终截图和 state 记录 Google AI 搜索结果、`q=AI`、`loading=false`、viewVersion 3。没有 CAPTCHA 求解或页面输入重试。

19:26:08.443–11.849 的 release 退出 0，回执中的 `inputReleased`、`artifactsCleaned`、`browserRetained`、`manualInteractionEnabled` 均为 true，且不是 `CleanupReceipt`。19:26:12.104–12.420 的认证 daemon stop 退出 0，原持有 Popen 实际退出 0，socket 消失。Runner 资源准备阶段诊断为 input 146 ms、store 完成及 prepare 147 ms；Runner 日志还记录 `CONTROL_RELEASE_DIAG ... status=0 retainedOwner=true`。

原 Runner 日志记录 windowNumber 1840；19:27:04 仅按已验证所属 Runner 的窗口号截图，显示完整标题栏、环境标识、地址栏与 AI 结果。19:27:54 的只读 NSRunningApplication/CGWindow 样本仍看到同一 Runner 28029 和窗口 1840（onScreen、1280×852），锁采样仍 held，超过 connect 开始 45 秒。PID 和窗口号仅用于采样归属，不作为控制路由。截图与窗口号支持同一窗口仍在；单靠只读窗口观察不能独立证明 WKWebView 指针身份。用户随后确认“完整窗口，能手动继续浏览”；并确认 19:25:35–19:26:12 操作其他 App 未发现干扰。这是用户对该次实际时段的反馈，不推及所有环境或场景。

证据：`.build/cli-control-001/retention-gui-013/evidence/steps.json`、`release.stdout`、`state.stdout`、`final.png`、`runner-log-increment`、`post-observer.json`、`post-lock.json`、`owned-window-after.png`、`manager-window-after.png`。owned-window-after.png SHA-256 `90f1c9738135e27bad07d65d586232b5ecff1cb0912862fb27bc7d1fd01f58ed`；Manager 1835 截图时间 19:27:35、SHA-256 `92d51f09a4be083daec0b25275a07bd8a8706b7f9db49d1e199d4fa660060b60`。截图均为获授权的各自 owned window ID，未做全屏抓取。

执行命令：`python3 .build/cli-control-001/retention-gui-013/driver.py --app /Users/yingzhang/safarier-cli-retention-testing-b91dd9f55dbe402ab56ae6bf3ced2609/Safarier.app --workspace /Users/yingzhang/safarier-cli-retention-testing-b91dd9f55dbe402ab56ae6bf3ced2609/workspace --profile 7064e28f-c8f9-4f1a-8524-21cccc723793`。READY 后视觉判断使用 `{"mode":"focused"}`；没有绕过 native eligibility。控制结束且需保留浏览器时，应在有效连接内使用 `control release --connection <connection>`；`control disconnect --connection <connection>` 保持原真实销毁语义，不用于保留窗口。完整调用需带同一 `--app` 和 `--runtime`。

## 边界与先前结果

012 同样在 webhp 完成 AI 搜索，但 release 返回 `INDETERMINATE_RESULT`，Runner 日志记录销毁/清理，未证明窗口保留或外部 cleanup 双 true。011 使用 Google 根地址时发生未关联主帧后继跳转，被原导航 gate 拒绝；013 使用 webhp 通过不证明根地址问题已修复；当前根地址的未关联跳转仍由原 gate 保守拒绝。滚轮控制仍禁用。011/012 不确定 daemon stop 均返回 `SESSION_BUSY`，在 Runner 已退和锁未持有后按授权中断各自实际 PTY 作业；进程查询为空但原 socket 残留，未声称认证 stop 或 cleanup 成功。

四项 `RunnerControlReleaseTests` 以 fake page 和真实 snapshot store 测过 finalized transfer、held/错误 ticket、权限撤销及未最终确认时销毁；它们不是 GUI 或真实人工接续证明。013 后未再对保留的浏览器输入、导航或关闭。
