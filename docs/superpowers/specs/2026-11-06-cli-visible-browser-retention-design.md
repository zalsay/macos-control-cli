# CLI 可见浏览器与手动接管设计草稿

状态：集成方案，供主 agent 复核；不代表实现或验收完成。用户已确认 AI 结束后在保留的完整窗口手动继续浏览。集成契约以 `.build/cli-control-001/retention-design-009/release-contract.md` 为准；App 和 Core/Manager/CLI 分工与共享类型由主 agent 协调。

## 目标和已知事实

显式成功释放控制后保留**同一个** `BrowserSession`、`BrowserWindowController`、`NSWindow`、`BrowserWebView/WKWebView`、configuration 和网站数据，由 Runner 持续持有原 profile 锁与浏览资源；用户可在同一完整窗口手动继续浏览。移交不得主动激活应用或制造输入；v1 不自动重新接管手动浏览窗口，新的 connect 按原 profile alreadyRunning 拒绝。

006 只成功打开 Google 首页，未发送搜索输入；008 采样到锁 held 和窗口 onScreen，用户确认当时窗口与 Manager 状态均可见并曾切换、拖动。两轮均未验证本设计或 Google 搜索完成。

原 `closeSession` / `disconnect` 仍为破坏性关闭，双 true 仍分别表示真实清理和原 owned Runner 退出；正常完成任务需要新的显式非破坏 release。原控制授权 45 秒、idle 30 秒、held 5 秒、原有动作/导航预算和 cleanup 2 秒保持不变，不静默续期。失败、权限或身份不明、输入未确认和未证实交接仍 fail closed。

## 当前代码与 UI 修正

原 `BrowserSession.makeBoundAutomationPage` 在原有 `BrowserWindowController` 上改成 borderless；本轮独立 UI 小修改为使用 titled 的后台专用 `NSWindow` 子类，继续复用原 toolbar、地址栏、环境标识和 WebView，`canBecomeKey`/`canBecomeMain` 均为 false，保留 `ignoresMouseEvents`、tabbing 禁用和 `attachBound` 的原身份/native input 检查。普通交互窗口默认路径不变。小修已由主 agent 审核；完整项目构建、真实窗口外观和 viewport/input 兼容性仍未验证。

当前后台窗口子类的 no-key/no-main 是固定返回值；手动阶段需要在同一个窗口内有明确、单向、经验证的阶段切换，恢复 key/main 能力和物理鼠标交互但不主动激活。不得创建替代窗口或仅切换 `ignoresMouseEvents` 就声称手动可用。

`BrowserSession.executionPolicy` 目前是初始化时的 `let`；`BackgroundPagePolicy` 会拒绝后台 UI 请求，`BoundFixtureNavigationDelegate` 替换原 controller 的 navigationDelegate 并依赖仍有效的 Binder。交接后须在同一个 WebView 上恢复原 controller navigation/UI delegation 与交互策略、清除自动化回调，验证菜单、工具栏、地址栏、网页交互及系统 UI；现有 configuration 和背景限制能否完整原位转换须由实现和测试证明。

## 有限实现方案：准备与提交

1. 外部请求 `AutomationAction.releaseControl`；Manager 拒绝外部直接调用 Runner 内部 `commitControlRelease(transferID: UUID)`。两阶段及其外部认证往返共享原普通动作的**同一个** 5 秒 deadline，不在提交阶段重置；Runner 的真实资源准备单独受一次 2 秒截止约束；提交遵循同一个 5 秒动作截止，不重置。
2. 准备前要求原会话 ready、无 held pointer、无 pending/in-flight、无 uncertain dispatch；在原 target、context、peer 和 owner 身份持续有效下，关闭并实际等待 native input 的 fence/activity，关闭截图 store 并检查实际结果。无证明时失败；准备后仍保留足够原对象所有权以便提交未发生时走原销毁路径。
3. 准备回执 `controlReleasePrepared` 关联相同 target、不可由调用方伪造的 transferID 与真实 `inputReleased`、`artifactsCleaned`、`browserRetained` 证明；阶段内继续保持 no-key/no-main、鼠标忽略和原 Binder，不得提前撤销认证通道。
4. Manager 在原认证 channel 上提交匹配原 prepared target/context/private ticket 的 `commitControlRelease`。只有真实验证并提交后，移交同一 session、window/WebView 与必须保留资源的强所有权，禁用旧 input/session/frame 权限；恢复同一 controller 的交互策略，不调用 activate 或 makeKeyAndOrderFront。最终 `controlReleased` 返回相同 target/transferID 和真实 `inputReleased`、`artifactsCleaned`、`browserRetained`、`manualInteractionEnabled`，不使用 `CleanupReceipt`，不表示 page 销毁或 Runner 退出。manual-ready 必须反映真实正在派发的 AppKit UI，不是排队待执行的未来切换。
5. 控制输入与截图产物 drain、浏览器所有权显式转移后归还短 Binder loan；保留 Runner 静态持有的原 `ProfileLock`。Manager 从**验证过提交回执的原具体 `AutomationRunnerClient`** 提取并在内存持续持有原 `OwnedRunnerProcess` 强句柄，只关闭控制通道，不调用 `closeAndWait` 或终止该 Runner；不得从 PID 文件、进程搜索或新公开 Runner listener 获取权力。

准备失败、错误票据、身份改变、超时、取消、输入/导航不确定或提交未证实，保留现有 fail-closed 销毁路径，不伪造成功。App 的提交线性点是 reducer 接受匹配回执、slot 再次完成 context.validate、resources.finishTransfer 成功，且 RunnerMain 强持同一 session/window/WebView/resources。此后已成为人工浏览 owner，旧控制通道失效、write-after 或 EOF 身份失败只终止旧控制作用域，不再拥有销毁该窗口或退出 Runner 的权力；不放宽认证，也不继续执行输入。Manager 未能验证回执时如实报告未知或清理未证实，不报告 cleaned=true。无新增 ack，也不以 EOF 独立证明 commit。

## App 生命周期与所有权切口

当前 `RunnerMain.start` 保存原静态 `lock`、后台分支使用 `CFRunLoopRun` 并在 `RunnerAutomationEntry.serve` 返回后 `exit(status)`。调整方案是在创建受控窗口前保持原 `.prohibited`/inactive 策略，直接运行**原外层 `NSApplication.run` 事件循环**；控制执行与成功移交后的手动浏览共用该循环，不嵌套运行、不重开窗口。仅有已经过上述线性点的强类型人工 owner 时，无论旧控制 serve 返回状态如何均保留同一进程，并记录实际 status；未达到线性点的返回维持原 shutdown、真实销毁和退出。

`RunnerMain` 的静态 controller/lock 可作为原 session 和锁的持有切口；`RunnerPreparation.OwnedResources` 的 bound 直连场景通常为空，其他仍需保留的资源必须有明确 owner。`BoundRunnerServiceSlot.beginClosing/drain`、`RunnerSessionResources.cleanup` 和其析构现会关闭 service/store 并销毁 page；只允许 proven committed transfer 走保留分支，不能取消异常清理。`OwnedBrowserAutomationPage.destroy` 仍用于原破坏性路径；新增交接须实际证明 input 已 drain 且避免旧自动化 delegate 在释放后持有失效 context。

原 lock loan 的归还不等同释放 Runner 原锁：`ProfileLock.Lease` 归还后，若原 owner 未请求 release，锁继续持有。`ControllerGenerationContext.safeClose` 当前只 release provider 和 close inspector，不自行终止 owned Runner；具体客户端、Manager Entry 的退出、deinit 和 daemon stop 仍须按新 owner 转移契约调整，不得把这一事实推断为完整 handoff 已安全成立。控制回执尚在通道中时，人工窗口若已被用户关闭，暂不提前退出；旧控制 serve 返回后再按真实窗口关闭状态退出。用户真实关闭最后窗口后，原 browser owner 完成正常资源处理，退出 Runner 并释放原锁。

## 关联模块与剩余验证

- App：`BrowserWindowController` / `BrowserSession` 的可手动阶段与原 UI、`OwnedBrowserAutomationPage` 的 drain/delegate 切换、`RunnerAutomationService` 的资源及证明、`BoundRunnerServiceSlot` 和 `RunnerPreparation` 的一次性所有权移交、`RunnerMain` 的外层 AppKit 生命周期。
- Core/Manager/CLI：由另一 worker 按共享契约实现 action/result 的严格编解码、internal commit 的边界、共同 deadline、重放与取消顺序、原进程句柄转移、保留状态及 CLI release。两侧具体共享类型以主 agent 分配为准。
- 风险：已有背景 WebKit configuration 的交互兼容性、原窗口 no-key 到人工可 key 的安全切换、input/fence 和 navigation 回调的晚到、store 真实清理、handoff 线性化及统一 5 秒动作／资源准备 2 秒预算、Manager 生命周期、提交后旧通道失败与 AppKit run loop/退出机制，均需定向证明。审过的 UI diff 不等于这些行为已实现或可用。

## 后续验收（本轮未执行）

验证 wire 严格 schema、错误票据、held/in-flight/uncertain 拒绝、取消与提交顺序、共同 deadline、重放及老 close 双 true。以经主 agent 核对的不可变候选，在真实桌面完成一轮 CLI Google 搜索 AI，不处理 CAPTCHA；以真实回执证明非破坏 release、同一 OS 窗口/页面、截图产物清理和锁在 45 秒后仍 held，再请用户亲自继续浏览并保留窗口。外框变化后必须重新观察截图，不能沿用旧固定像素哈希。各项结果应分别报告，006/008 不能替代最终验收。
