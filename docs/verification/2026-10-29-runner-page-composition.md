# 第八批：Runner 页面、控制器、通道及截图组合

日期：2026-10-29（Asia/Shanghai）

## 状态

**本批候选代码及以下无 GUI 验证完成；生产页面自动化仍不可用。** 已补真实对象适配器和实际组合 helper，但没有放开原 admission，也没有进行真实悬停、按住、拖动、键盘或零 click/drop 验收。

仓库 `/Volumes/RC500/dev/safarier`，分支 `mcc-safarier`，HEAD `2f32d21248deaffd8c8c1152a39912aa46350c7e`。前七批未提交改动保留；本批没有 commit、push、安装或发布。原 211 个文件中 203 个未改，另 8 个限定路径修改；新增 13 个文件（含本报告）。200 个 Source/Test/scripts 文件在最终编译和三轮测试期间按 SHA-256 冻结。

## 代码接线

- `/Volumes/RC500/dev/safarier/Sources/Safarier/Automation/RunnerAutomationPage.swift`：唯一页面契约，数据模型复用既有 identity/viewport/state/result；snapshot 只承载原生 PNG 和同一 viewport。
- `/Volumes/RC500/dev/safarier/Sources/Safarier/Automation/OwnedBrowserAutomationPage.swift`：固定绑定实际 BrowserSession、controller、BrowserWebView、NSWindow、windowNumber、几何和版本，UUID 不来自标题、坐标或索引。拒绝交互 Session、可见/key/main/active 窗口和变更对象。
- `/Volumes/RC500/dev/safarier/Sources/Safarier/Automation/NavigationCorrelation.swift`：Foundation 对象身份与 epoch 关联；真正 WKNavigation 回调仍由原 BrowserWindowController delegate 转发，不替换 navigation/UI delegate。
- `/Volumes/RC500/dev/safarier/Sources/Safarier/Browser/BrowserSession.swift`：专属 page factory 先执行原固定拒绝，才复用原 makeController/newWindowContentSize；设置 orderOut/ignoresMouseEvents/tabbing disallowed，更新 overlay 并 layout 后 attach。makeAutomationService 组合真实 permission repository、专属 page factory 和既有 snapshot store。
- `/Volumes/RC500/dev/safarier/Sources/Safarier/Browser/BrowserWindowController.swift`：只增加后台导航/关闭/进程丢失回调，后台导航失败不转入隐式 error-page load；交互分支仍走原方法。后台 overlay 始终隐藏，普通交互初始化不变。
- `/Volumes/RC500/dev/safarier/Sources/Safarier/Automation/NativePageInput.swift`：原生事件、TLS、Unicode、mouse fence、snapshot 仍是同一实现。正常 open 和诊断构造共用唯一 activity begin；增加 gated viewVersion/readiness/finish acknowledgement。重复 close 不再把未收到的 finish 回调伪造成已完成。
- `/Volumes/RC500/dev/safarier/Sources/Safarier/Automation/RunnerAutomationService.swift`：组合原 SessionMachine、RunnerAutomationController、AutomationRunnerServer、SnapshotStore；真实 repository 读取和文件 I/O 在 detached 工作中。打开前后重读许可，每个会话动作继续由 controller 重读；open receipt 重播不重新创建页面或续期。
- `/Volumes/RC500/dev/safarier/Sources/SafarierCore/AutomationSessionMachine.swift`：仅增加 readonly boundViewport，删除该行可重建原文件 hash；没有第二套 session/replay 状态机。
- `/Volumes/RC500/dev/safarier/Sources/Safarier/RunnerMain.swift`：本批仅把原早期 unavailable bootstrap 调用换成 RunnerAutomationEntry。Entry 在任何页面或 artifact 创建前仍直接服务 unavailable，**即便将来 admission 改为 true，目前另一分支也仍 unavailable**，不会暗中启动缺失的配置准备。

### 取消与清理的保守含义

旧 activity 的 unknown/pending/held 销毁需求不能在导航换 driver 时丢掉。导航先检查 sticky 销毁需求并等实际 finish 回调，再加载；同一个 30 秒本地 deadline 覆盖退役，在 load、新 driver 和最终返回前均复核。超时不是完成证据。

真实 page.destroy 使 epoch 失效、停止活动并释放精确自身对象，但始终返回 false：关窗口/detach/activity finish 不足以证明整个 WebView、按住状态或零 click/drop。Runner 不声称已终止自己；这种证明仍需要 Manager 观察本次 owned Process 的真实退出。

取消已经开始的原生动作可能有副作用，不能靠改回执抹掉，也不补 mouseUp/click/drop。晚到 PNG 或动作结果不得发布路径或恢复 ready；自身 store 始终尝试清理，不因 page identity 变化就跳过自己的文件清理。

## 主代理复核与修正

生产代码由实际上下文为 `gpt-6.1-terra/high` 的两个 worker 实现，设计与 code review 全由主代理执行。恢复旧 worker 时发现路由变为 Sol/xhigh，已在其修改文件前停用并更换 Terra；初次与修正后的实际 routing 快照均保留。没有让 worker 承担 code review。

主代理发现并由 Terra 修正：

1. **打开会话的取消/过期窗口**：Opening 持有同步取消 flag、绝对 monotonic deadline 和已采用的完整 identity，factory/后续 continuation/发布前重核；失败打开为该 owner 的终态，避免反复取消创建无限清理任务。
2. **专属页面初态**：原 observe 仅 `.new`，不会自动隐藏初始 start page；专属 factory 显式 updateState/layout 后才固定对象与几何。保留源码 RED/GREEN，不把源码检查当 GUI 验收。
3. **导航 activity 交接**：不丢弃 sticky 销毁需求，不在旧 activity finish 未确认时开启新 lease；finish/ready 和本地 deadline 检查都是候选代码，真实 SPI 行为仍未测。
4. **动作完成与调用方取消竞态**：联合回归抓到“page 内取消后仍回复成功”。主代理独立实际 controller 反例旧版 **100/100 stale success**；最小修复以锁在线性化点认领完成，并核对完整 ticket。最终每轮 **100/100 失败回执，0 stale success**。保留原 sideEffects=possible，不声称撤销了输入。
5. **open ID 跨动作别名**：open 的 ID 原可被合法 token 的 click/cancel 再次使用，绕过初始 receipt。主代理独立 RED 只通过 4/9；修正后 9/9，拒绝 sink/cleanup 副作用；错误 token 仍优先 SESSION_NOT_FOUND。只保护既有单一 open receipt，没有另造 ledger。

主代理的 close 测试曾把“page.destroy 已被调用”等同“异步 store.close 完成”，在 stopping 阶段过早要求最终 receipt。根因是测试驱动，已改为有界等待实际终态（允许原 SESSION_BUSY），没有改变原 reducer 或降低最终 receipt/文件清理断言。失败日志保留为 `harness-close-while-stopping.*`。

## 最终验证

原始命令 argv/stdout/stderr/exit、冻结 hash、RED 与 GREEN 位于：

`/Volumes/RC500/dev/safarier/.build/automation-stage8-main-review/`

### 冻结后联合测试：连续三轮，每轮 2,168 项

| 类别 | 每轮检查数 |
|---|---:|
| Protocol / Channel / Wire | 340 / 28 / 117 |
| Controlled Runner / Script / Manager launch | 56 / 59 / 64 |
| Policy / Session / UI boundary | 117 / 354 / 395 |
| Controller / Native preflight / Snapshot store | 319 / 60 / 69 |
| Multiplex / Owned process / Runner service | 35 / 104 / 51 |

其中 service 使用明确的 Foundation page fixture，不创建 WebView、真实页面或事件。held cancel 的“无额外输入调用”只证明组合层没有合成 up/click/drop，不能代替真实网页计数验收。

### 主代理独立测试：下列各连续三轮

- Runner service 35 项：真实 socket/新 service EOF hook、精确 target/instance、原 reducer replay、导航版本只增一次、许可撤销、私有截图存储与晚到 PNG 收尾。
- 打开取消/超时 6 项，open ID 别名 9 项；均含对象与副作用断言。
- 同步完成取消竞态每轮 100 次；导航关联每轮 1,000 轮、9,000 次对象/epoch 检查。它们不运行 WebKit。
- 前批独立回归：controller 67、UI boundary 225、session 356、policy 1001（53 项 synthetic inventory）、script 281、native preflight 133、snapshot POSIX/ACL 88、passive caller 39；owned/client/server 19/20/13，均通过。
- metadata/sdef 32 项通过，仅在自有目录写 metadata，不注册或运行 App。

### 产品与门禁

- 最终普通 Safarier 产品编译链接 exit 0，无 warning；使用单命令 ManifestAPI VFS overlay，不修改系统工具链或开发目录。
- 包含所有实际 App 源码和诊断 define 的 probe 二进制编译链接 exit 0，无 warning，**未执行**。普通产品诊断 ctor/trace 符号 0，诊断二进制对应符号 5。
- 链接本次普通产品对象的小 CLI 三轮通过：Factory 每轮 8 项早期拒绝，credential/privacy 调用 0；Native admission 仍拒绝；实际 App Entry 的握手/capabilities/open/click 均 unavailable，NSApplication 全程 nil。
- 新 wrappers 仅 syntax parse；shell syntax、聚焦源码检查、git diff --check 通过。实际 import XCTest 仍报 `no such module 'XCTest'`，没有执行正规 XCTest/AppTests。
- 最终自有 fixture 进程无残留，原 sparse omissions、其他 checkout 与 5 个受保护工具链文件保持原状。

复核入口：

```sh
cd /Volumes/RC500/dev/safarier
python3 /Volumes/RC500/dev/safarier/.build/automation-stage8-main-review/Validate.py
python3 /Volumes/RC500/dev/safarier/.build/automation-stage8-main-review/ProductQA.py
python3 /Volumes/RC500/dev/safarier/.build/automation-stage8-main-review/SymbolReview.py
python3 /Volumes/RC500/dev/safarier/.build/automation-stage8-main-review/FinalReview.py
```

## 尚未完成，不得据此启用

1. 实际 Runner 的 Profile/代理/sing-box/语言时区/数据存储配置准备仍未接到新的后台 page factory，Entry 明确继续 unavailable。
2. `workspace.root/automation-artifacts` 必须由后续受控准备流程提供可信预置 0700 目录；本批 helper 不 mkdir/chmod 现有路径，更不根据 wire 路径清理目录。缺失时 fail closed。
3. Manager 侧会话 registry、持久许可保存/重载的即时撤销通知、ScriptCommand 到真实服务的路由仍未完成；不能把每动作 repository 重读说成跨进程原子撤权。
4. G0/G1/G2、53 项真实 UI 能力、真实 hover/held/drag 与用户同时在其他 App 使用键鼠的验收未通过；本轮无实际 App/GUI/probe/cursor/原生输入或 Apple Events 执行。
5. NativeInputPreflight、WebView 工厂、Manager ScriptService 的原硬拒绝未变，默认脚本启用状态未变；没有全局鼠标/键盘、System Events、DOM/JS 输入兜底，也没有“抢焦点再恢复”。
