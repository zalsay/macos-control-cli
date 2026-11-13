# 2026-10-29 后台 UI 策略与会话状态核心

## 状态

- `/Volumes/RC500/dev/safarier`，`mcc-safarier`，HEAD 仍为 `2f32d21248deaffd8c8c1152a39912aa46350c7e`。本批次没有提交、推送、安装、发布或运行真实 Safarier App。
- 两名 Terra worker 实现，主代理执行全部 code/design review、独立反例、最终组合验证与进度文档。重新读取实际 turn_context，两者均为 `gpt-6.1-terra` / `high`；没有 reviewer 子代理。
- 本批完成 Task 2 的**策略/能力记录模型及构造前门禁**，和 Task 6 的**无 GUI 会话状态/效果核心**。这不是 Task 2/6 全量完成，不是 G1/G2 已通过，更不是可操作页面的产品版本。
- 没有创建 NSApplication、WKWebView 或真实窗口，没有发送/执行 Apple Events、请求系统权限、操作系统鼠标键盘、使用 DOM/JS fallback 或修改系统工具链/TCC。Foundation 进程回归仅执行自有 fixture。

## 1. 先梳理原代码，不叠加第二套浏览器

主代理沿已有调用链确认：

1. 原 `/Volumes/RC500/dev/safarier/Sources/Safarier/RunnerMain.swift` 普通路径由原配置工厂组装代理、数据存储、语言/时区及隐私设置，再创建 NSApplication 和 BrowserSession；受控背景分支仍在更早位置运行 unavailable bootstrap，不能落入普通 GUI。
2. `/Volumes/RC500/dev/safarier/Sources/Safarier/Browser/BrowserSession.swift` 的 start/openWindow/openTab 会激活或前置窗口、合并标签；这些是人工路径，不适合直接作为后台执行器。
3. `/Volumes/RC500/dev/safarier/Sources/Safarier/Browser/BrowserWindowController.swift` 原 JS 对话框、文件选择、媒体与 HTTP 页面认证会构建 sheet；下载会交给原 DownloadsController，WebContent 崩溃会重新载入。
4. `/Volumes/RC500/dev/safarier/Sources/Safarier/Browser/BrowserViews.swift` 的 willOpenMenu 是菜单定制，不是所有平台 popup 的展示前拦截；不能由它推断选择框/日期/颜色/拖放均已封住。
5. 原工厂启用元素全屏、对有声媒体要求手势，不等于后台静音或点击后也不会发声。当前 SDK 中的公开回调和声明只作源码索引，不证明当前运行时已具备完整禁用能力；没有猜测私有 selector 或安装新 hook。

本批复用现有 codec、session token、replay cache、target/viewport、错误/回执与 limits；没有新增服务、浏览器、通用输入执行器、网络监听器或另一套 wire/cache。

## 2. UI 策略与构造前拒绝

### 策略与能力模型

`/Volumes/RC500/dev/safarier/Sources/SafarierCore/BackgroundPagePolicy.swift`：

- `BrowserExecutionPolicy` 为 interactive / automationBackground。人工策略返回 preserveExistingBehavior，继续由原逻辑判断，而不是无条件授权。
- `BackgroundUIRequest` 逐项覆盖 47 种请求类别，其中包括 unknown 和单独的 proxyBoundAuthentication。危险/未知后台 UI 请求返回固定、脱敏的 INTERACTION_REQUIRED 阻断决定。
- 代理绑定认证只表示保留原拥有者已验证的绑定流程，不代表允许网页密码 UI、任意凭据或未知 challenge。网页 HTTP/证书/WebAuthn 等仍是危险入口。
- 53 项 `BackgroundSafetyControl` 记录要求精确目录、无缺失/重复/未知项，以及同一 runtime build 的 signature/readback/isolated-negative-fixture 三种记录。unverified/unavailable/conflicting、错构建或空证明均不完整。
- `isComplete` **只检查提供的记录模型是否完整一致**，不读取引用内容、不验证 OS 来源、不自动探测安装 hook。测试的完整记录是合成数据，不能变成 G2 证据；生产 `.unverified` 仍为 false。

### 原工厂的最小改动

`/Volumes/RC500/dev/safarier/Sources/SafarierWebKit/WebViewConfigurationFactory.swift`：只新增默认 `.interactive` 的 executionPolicy 参数和首行 guard。`.automationBackground` 无条件抛出 UI_POLICY_UNAVAILABLE，早于 WKWebViewConfiguration、DataStore、凭据及隐私适配器调用。没有允许调用方传 Boolean 或合成 capability 来绕过的参数。

恢复这两处增量后的文件与批次前内容完全一致；原代理 fail-closed、语言/时区、DataStore、普通浏览设置及原 API 调用方式保留。没有为了验证后台而修改人工窗口/菜单/媒体委托或改变其权限策略。

主代理将**正式产品实际编译的 Core/WebKit/ObjC library 对象**链接到无 GUI CLI，直接调用真实 factory，不替换工厂实现。连续三轮，每轮 8 种 Profile opt-in/代理配置组合均提前拒绝，CredentialSpy=0、PrivacySpy=0。DataStore/WK 配置创建前后顺序另由实际源码 guard 位置确认，未声称已有可注入的 DataStore 运行时计数。

### G2 诚实矩阵

版本化矩阵：`/Volumes/RC500/dev/safarier/docs/verification/2026-10-29-background-ui-policy-matrix.json`。

| 类别 | 控制入口 | 当前证据 |
|---|---|---|
| 窗口生命周期 | start/openWindow/openTab/reopen/cycle，初始 orderOut、非 key/main、物理鼠标穿透、不切 Space/前置 | 原拥有者定位完成；运行时/回读/图形负例未验证 |
| 网页 UI | 新视图/关目标、alert/confirm/prompt/beforeunload、文件/目录、媒体 | 原委托定位完成；未安装正式后台拦截 |
| 应用与下载 | 保存、打印、分享、下载 | 原拥有者定位完成；未验证后台取消 |
| 敏感权限 | 定位、通知、屏幕捕获、剪贴板 | 没有完整展示前阻断证明 |
| 媒体/全屏 | 元素/视频全屏、PiP、pointer lock、有声播放/通知声、静音/禁自动播放 | SDK/源码索引完成；没有 runtime signature/readback/负例 |
| 原生 popup | select/date/color/autocomplete、context menu、长按、链接预览 | willOpenMenu 不计作完整前置拦截 |
| 系统拖放 | HTML drag 与 OS drag | 没有阻止系统 drag session 的已验证机制 |
| 认证/外部系统 | 页面 HTTP/证书/WebAuthn/Passkey/ApplePay、外部协议 | 没有完整后台取消证明；不冒充已认证代理绑定 |

矩阵逐条保留全部 53 项，runtimeSignature/readback/isolatedNegativeFixture 均为 null、status 均为 unverified。当前系统为 macOS 26.6.2/25G83、arm64、WebKit 21624.5.1.11.3，SDK 26.5；这些是环境元数据，不是图形验收证据。**G2 继续 blocked。**

## 3. 会话状态与身份隔离

`/Volumes/RC500/dev/safarier/Sources/SafarierCore/AutomationSessionMachine.swift` 是单一串行拥有者使用的同步 reducer/effects，不是另一套 Runner 或 native scheduler。

- open 的纯预检要求显式许可、无人工作业 Profile 占用及 canonical token；bind 精确绑定 Profile/Runner/window/page 和合法 viewport。这里的许可、占用、目标和时间是**拥有者提供的事实**，不等于已读取实际磁盘、锁、OS 身份或 WebView 对象。
- opening → ready → held，另有 blocked/stopping/closed。操作在 token、当前权限、完整目标、typed codec、状态/边界/viewVersion 检查后才产生 dispatch **意图**；错误 token 不能撤销健康会话或续租。
- 复用现有 ReplayCache 做活跃请求的 inFlight/replay/不同 payload 拒绝/256 项容量，保持 insertText 的精确 UTF-8 身份；busy、非法坐标/按钮状态、错误 token 等不延长 lease。
- 30 秒空闲 lease，5 秒单次按住绝对期限从 down 分派开始算，不因完成时刻、读取或其它有效操作延后。启动/普通动作/导航/收尾使用已有 limits；非法或倒退的 monotonic time fail closed。
- cancel/close 可立即打断在途导航，不排队等待它完成。`reply` 是本次同步输入的回复，`completion(ticket,reply)` 对应已经挂起的操作，`awaitCleanup(ticket)` 标识挂起的 close，避免相同 requestID 在期限边界混淆路由。
- 操作 ticket 与 cleanup ticket 都包含每个 machine 的独立 instance UUID 和 epoch。跨会话即使复用同一 requestID/版本号也不能互认回执；迟到回调不能恢复 ready 或伪造其它目标的清理成功。
- getState 核对完整 target、viewVersion、sessionState；截图回执核对完整 viewport，包括像素尺寸、比例和 pageZoom，而不是只看 logical width/height。
- 目标/权限/EOF/进程退出/期限/危险交互等产生自身目标销毁意图，不生成补发 mouseUp/click/drop。cleanup 只有匹配的 ticket 才接受明确回执；2 秒到期则关闭，默认 receipt 为 cleaned=false / terminatedOwnedRunner=false，不能虚报退出。
- 活跃 cache 在最终关闭释放，不冻结/伪造 monotonic time。终态只保留 UUID、close/cancel 类别和一份共享 CleanupReceipt；容量有界，最多 256 个普通 ID，另允许缓存满时原始安全关闭的一个额外 ID。关闭回执重复调用稳定，同 ID 改动作或旧操作 ID 改作 close 被拒绝，终态不 dispatch/续租。

**尚未接线：**没有 AutomationManager/RunnerAutomationController、跨 Profile 原子注册表、每次真实持久权限重读/GUI 撤权通知、真实对象 UUID 映射、进程退出确认、定时器/native sink/快照配额与文件清理。tick 的期限效果只有未来拥有者按时驱动后才能形成真实时间保证；正确 ticket 也不是实际进程已退出的证明。当前 AppleScript service 和 Runner bootstrap 原样保持 unavailable，不能通过这个纯模型执行页面动作。

## 4. 主代理复核发现与修正

1. **unknown 安全项错误地进入已知可验证目录**：移除该安全 control，保留 unknown request 的阻断；等数量替换未知项也拒绝。主代理原代码快照运行 RED 显示 unknown 可以被合成证明标为 complete，最终 GREEN 通过。
2. **跨会话 ticket 碰撞**：旧 ticket 只有 epoch/requestID，新会话重用 requestID 可接收旧会话的 nativeDelivered。主代理 RED 实际复现 tickets 相等且误接收一个 completion；补 instance UUID 后同一反例 GREEN。
3. **终态 ID 冲突与回复路由**：关完后同 ID 从 close 改 cancel、旧 click ID 改 close 必须拒绝；在途期限/取消回复增加 ticket 路由，不能误完成新调用。
4. **截图/状态不一致**：补完整 viewport 与 sessionState 校验，错误比例/像素/zoom 不得变成可信坐标回执。
5. **清理回调缺少所有权**：补 cleanup ticket；其它会话的“已退出”回执不能结束本目标清理。
6. **为终态重放而冻结 cache 时钟**：移除伪造时间，按实际时间使用原 cache，终态释放活跃 payload，改用有界的关闭身份元数据。

主代理读取了 worker 的实际 RED/GREEN 日志；独立 RED/GREEN 快照和最终反例保留在 `/Volumes/RC500/dev/safarier/.build/automation-stage4-main-review/`，worker 明确失败/成功证据在 `/Volumes/RC500/dev/safarier/.build/automation-session/`。不把首次缺类型的编译 RED 当作真实安全行为失败。

## 5. 最终独立验证

证据目录：`/Volumes/RC500/dev/safarier/.build/automation-stage4-main-review/`。最终所有 Core 源码静态编译，避免串用 worker 动态模块；已冻结源码 hash 另行核对。

| 检查 | 实际结果 |
|---|---|
| 联合共享 cases，3 轮 | 每轮 340 protocol + 28 channel + 117 wire + 56 controlled-process + 59 script + 64 launch/menu + 117 UI policy + 354 session = **1,135 项**，均 exit 0 |
| 主代理独立 session，3 轮 | 每轮 **356 项**，含每轮 100 个跨会话 ticket、清理归属、真实时间边界/容量/终态/坐标反例，无 native 输入 |
| 主代理独立 policy，3 轮 | 每轮 **1,001 项**，与独立 53 项目录核对，对每一控制逐项删证据、换构建、填 unknown/空/冲突等；完整证明仅为合成数据 |
| 真实配置工厂，3 轮 | 每轮 8 个调用均提前 UI_POLICY_UNAVAILABLE；凭据读取和 privacy apply 均 0；无 GUI |
| 前一批 script/adapter，3 轮 | 每轮 281 coordinator + 39 被动 caller parser 检查通过 |
| 原独立回归 | request corpus 71、reply corpus 47、roundtrip 28、握手/持续连接 16、真实自有 Foundation 坏握手子进程 5 全通过 |
| 生命周期/打包 | 299,592 reducer transitions 和 32 metadata/sdef 检查通过；不代替实际 App/Apple Events |
| 正式产品源码 | 新缓存、命令级诊断 VFS overlay 全产品编译链接通过，冻结后最终重建 exit 0，无 warning；未执行产物 |
| 独立脚本 | test-background-page-policy.sh 117 checks；test-automation-session.sh 354 checks，均 exit 0 |
| 正规测试限制 | 本轮 XCTest 探针仍 no such module XCTest；新增 XCTest wrappers 只做语法检查，原完整测试及 GUI 未运行 |

overlay 只作用于本命令的 Manifest 接口读取，不修改系统 SDK 或全局 xcode-select；不能当作发布工具链已修复。没有删除旧断言、引入假 XCTest、开放真实脚本控制或用全局输入补失败。

## 6. 门禁与下一步

- **G0 未全量通过**：正规 XCTest、完整旧回归、release/正式包验收没有完成。
- **G1 未通过**：真实 AppleScript 冷/热启动、多实例唯一路由、系统权限与焦点/窗口/菜单行为尚未隔离验收。
- **G2 未通过**：53 项真实 UI 拦截仍未验证；没有因为 catalogue/model/早拒绝成功而开启通用输入。
- 下一阶段沿原 BrowserSession/WindowController/配置工厂落实具体展示前拦截和专属后台目标/收尾，并把本状态机接入既有受控链路；仍需独立图形环境证据，不能只改 unavailable 为 active。
- 本批仍未修改 shipping 脚本开关、Manager 激活代码、Runner unavailable 分支或原输入桥。最终范围检查 **90/90** 通过：批次前 162 个文件中只修改约定的工厂与两份设计/进度文档，另 159 个保持 hash；新增 11 个代码/测试/脚本文件及本报告/矩阵，共 13 个。工具链 hash、全局 developer directory、邻接仓库 Git 状态快照保持不变，自有 helper 遗留 0、staging 为空。详见证据目录 final-review.json；不授权运行候选 App、提交/安装/发布或扩大输入白名单。
