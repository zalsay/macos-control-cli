# 2026-11-06 内测 App 接入与有限验收

**状态：同一受控页面的可见观察、Selenium 原生输入及真实协议 cleanup 已通过定向验收；Google 仍返回异常流量验证页面，搜索结果未验收。** 用户另行反馈普通管理界面和同一网页正常，已确认使用的是之前安装的 Safarier，不计入新 testing App 的普通 UI 验收；用户随后确认原 testing 包再次双击时管理界面出现；用户随后反馈修复包人工打开“打开正常”；004 测试版的原生输入与 Finder 人工打开仍待验收；此前已实际经 AppleScript/Binder 到达 Google 首页。wheel 仍 denied。本结果不覆盖 IME、任意网页/文本、DOM 元素原子绑定、完整 G1/G5、公证或发布。

## 接入与限制

双宏 testing App 接入普通 UI，以及 AppleScript 经原 Binder 控制同一个自有受控页面（内测支持同页只读可见观察）的 HTTP(S) 显式导航和非 wheel 输入。签名 fixture 仅为受控 bootstrap，导航后用原 context 重建 input。后台 profile 需显式 opt-in，仍受 ephemeral、直连、无 SPI、不跟随代理等原 factory 条件限制；用户普通交互浏览不要求关闭所有 SPI，后台 opt-in 可保持关闭。内测默认 workspace 为 `~/Library/Application Support/Safarier Test`、Keychain 独立；默认 root/locks 的安全创建、owner/非 symlink/0700 校验和进程早期 umask 077 已接入，override 沿原 Core 验证。

URL admission 用于 scheme 和状态检查，**不等于 navigation identity**；原 WKNavigation started/commit/finish correlation 必须保留。只读 DOM focus 检查不是原子的 DOM 元素绑定，JS 不是身份根；`nativeDelivered` 不能单独保证 DOM 效果或敏感字段安全。原 Binder C、NativePageInput、身份、预算和真实 cleanup 门禁未改；没有 global input 或 PID 路由 fallback。本轮未安装、commit 或 push。

## 构建、TCC 与历史失败

首次 testing build 因 SDK `callAsyncJavaScript` callback 参数标签失败；最小修正后第二次 full build 和 host compile 成功。main 源码/产物核查见 `/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/main-source-review-002.json`、`/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/main-artifact-review.json`。本轮 App 为 `/Users/yingzhang/safarier-testing-1be4abcbe9e443c58296eb913ba656e7/Safarier.app`，不是安装或发布。

09:53:26–09:53:27 的 false TCC preflight 对新 `sh.safarier.testing` 目标返回 `-1744`，未创建 session、导航或输入；保留停止证据 `/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/main-permission-stop-review.json`。用户随后明确允许一次 consent preflight，**10:03:37–10:03:41** 结果 exit 0、permission allowed；授权记录 `/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/user-consent-authorization-001.json`。

`navigation-snapshot-002` 于 10:04:08–10:04:26 在客户端 OSA 10 秒等待处报 `-1712`；没有成功导航回执或协议 close proof。Runner 局部 cleanup 和 Manager 退出状态不能替代协议 close；该失败历史保留，见 `/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/main-runtime-review-001.json`。后续仅 testing navigate 的客户端 OSA/外层等待调整为 35 秒；Core 原 30/45/5/2 秒预算和身份、cleanup 门禁不变，见 `/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/main-harness-timeout-review.json`。

## 启动事件修复与定向观察

原实现在 `app.run()` 前过早注册 handler；此次唯一产品修复将原有 handler 安装移至 `applicationWillFinishLaunching`，不改变状态机、身份或 cleanup。Apple 的 [NSApplication 文档](https://developer.apple.com/documentation/appkit/nsapplication)将此生命周期方法作为注册自定义 Apple Event handler 的一般推荐位置。

- 旧诊断包显式 `oapp` 基线 `002` 未记录 interactive（10:50:33–10:50:45），见 `/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/normal-launch-debug-001/observation-002.json` 与 `phases-002.json`。
- 修复包显式普通启动 `003` 于 10:51:39–10:51:51 记录 interactive、`visible=true` 和 regular policy，见同目录 `observation-003.json`、`phases-003.json`。
- 修复包 automation `noop` 启动 `004` 于 10:52:31–10:52:43 未显示管理窗口，保持 accessory 且 inactive，见同目录 `observation-004.json`、`phases-004.json`。

这些是 NSWorkspace 显式启动意图的定向 GUI 观察，不是修复包的 Finder 人工首次启动、真实网站、Binder、输入或 cleanup 复验。下述 10:15 后台网页输入和 cleanup 证据只属于此前原 testing build。

## 真实网页后台测试

- `navigation-snapshot-003`：北京时间 **10:09:48–10:10:02**，同一 owned target 的 viewVersion 从 1 到 2，获得网页截图及协议 close；Manager 在 841 ms 接受清理 proof。main 核图和记录见 `/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/main-runtime-review-002.json` 与 `/Users/yingzhang/safarier-testing-1be4abcbe9e443c58296eb913ba656e7/navigation-snapshot-003/results/stdout.jsonl`。
- `native-input-001`：北京时间 **10:15:25–10:16:05**，在 `https://www.selenium.dev/selenium/web/web-form.html` 的指定普通文本输入位置，7 条 native sequence 为 `1–7`、buttons 均为 0、viewVersion 为 2。main 查看最终实际 PNG，文本为 `Safarier Test 123中!`；文件 `/Users/yingzhang/safarier-testing-1be4abcbe9e443c58296eb913ba656e7/native-input-001/results/form.png`，SHA-256 `7830999d1a491c812a0db62d0d5ec928e6433c95816933e8ecf1d3c5f10b4238`。日志及结论见 `/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/main-runtime-review-003.json` 和 `/Users/yingzhang/safarier-testing-1be4abcbe9e443c58296eb913ba656e7/native-input-001/results/stdout.jsonl`。

输入轮 Runner 记录真实 page destroyed、store cleaned、`removedFiles=2`、`retainedFiles=0`、`directoryRemoved=true`，artifact base 为空；Manager 在 931 ms 接受 proof，协议 receipt 为 `cleaned=true` 且 owned Runner 已终止。Manager status 15 仅表示 owned Manager 后续退出，不替代 page/store 或协议 close proof。

## 修复版 Google 搜索测试与定位

修复版与受审交付 App 的 9 项 artifact hash 一致。Google `002` 中，main 查看了实际 1280×772 首页截图；同一会话随后显式导航到 AI 搜索返回 `INDETERMINATE_RESULT`，未确认搜索结果。新会话 `003` 直接显式搜索同样返回该错误，耗时 2371 ms，没有搜索截图。见 [002 主审记录](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/google-search-001/main-runtime-review-002.json)、[003 主审记录](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/google-search-001/main-runtime-review-003.json) 和 [首页截图](/Users/yingzhang/safarier-google-aa786ebf93df432d93eaffca8d9604bd/google-search-002/results/hover.png)。

诊断版 rev002 于北京时间 11:52:44–11:53:00 的 Runner 记录显示，相关序列为 `explicitBegin → didStart → didCommit → didFinish → policyCancel`，记录中没有 `serverRedirect`。取消时 `mainFrame=true`、`initialPending=false`、`redirectPending=false`；后续元数据为 `navigationType=-1`、`explicitURLPresent=true`、`urlEqualsExplicit=false`、`sourceIsFixture=false`、`sourceURLMatchesCurrent=true`、`urlIsWebURL=true`，随后 block。这表明现有 pending 导航准入拒绝了页面后续主框架 action；现有证据不能精确区分 JavaScript 与 meta-refresh 等发起方式，也不能将 Google 搜索称为已修复。原始提取见 [rev002 诊断](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/google-search-001/navigation-diagnostic-001/diagnostic-extract-002.json) 和 [运行收据](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/google-search-001/navigation-diagnostic-001/execution-result-002.json)。

此前 Google 搜索轮次未取得 `cleaned=true` 且 `terminatedOwnedRunner=true` 的完整协议 close 双确认；后续 navigation-fix 004 的独立结果见下。Runner 日志中的 page destroyed/store cleaned 等局部 cleanup 单独记录；owned Manager 退出不能替代协议 close。首次 Process 普通启动出现路由干扰后，Google 专用测试入口改用既有 NSWorkspace/noop 后台启动，保留 parent 1、UID、birth、exepath、owned handle、唯一 inactive/accessory 等约束；首次发现两个用户 Manager 时仅在取得明确授权后退出。该测试使用显式 navigate URL，没有全局输入、native click、insertText 或 Enter 提交，当前不能宣称完整鼠标提交链已支持。

后续修复范围是沿现有 `NavigationCorrelation` 与 OwnedPage，为原请求内同一受控 WebView 的后续主框架导航建立可验证关联，包括 source frame、原导航代际、每跳有界、30 秒导航和 45 秒寿命、旧回调不复活以及原 cleanup；不能简单 allowAny，也不能依赖 DOM、PID 或 global fallback。该修复已在 004 轮通过原生导航与真实 cleanup 定向验收，Google 搜索结果仍未验收；现有身份、预算与 cleanup 门禁保持。

### navigation-fix-001 进展与未完成项

- 第一版限定同一 owned WebView、已完成父导航、关闭的 input 和单次有界许可；main 对三个变更文件的完整源码审核见 [source review 001](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/navigation-fix-001/main-source-review.json)。实际运行确实记录第一条 finished continuation 已 reserved 和 adopted，但后续 provisional 阶段的主框架 action 被拒绝；Google 搜索未成功。见 [runtime review 001](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/navigation-fix-001/main-runtime-review-001.json) 和 [运行证据 001](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/navigation-fix-001/execution-evidence-001.json)。
- 第二版针对已授权但尚未 commit 的 descendant 保留上一个已完成来源的证明；main 源码审核见 [source review 002](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/navigation-fix-001/main-source-review-002.json)。实际运行再次完成首条 continuation 的 adopted，但后续 action 在 commit 前仍被拒绝；当时具体 guard 原因未知。见 [runtime review 002](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/navigation-fix-001/main-runtime-review-002.json) 和 [运行证据 002](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/navigation-fix-001/execution-evidence-002.json)。
- 第三版仅增加固定字段诊断，见 [source review 003](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/navigation-fix-001/main-source-review-003.json)。实际诊断显示 source/target 均为同一 owned WebView 的主框架、source URL 匹配已完成来源证明、input 已关闭、当前是已知但未 commit 的 descendant，然而 state validation 为 false。main 随后定位到源码中 `viewport → checkedObjects → acceptsCurrentURL` 在候选 URL 被准入前执行，存在循环次序；在 003 时**实际运行时 current URL 是否等于候选 URL 尚未证明**；后续 004 的运行证据见下。见 [runtime review 003](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/navigation-fix-001/main-runtime-review-003.json) 和 [运行证据 003](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/navigation-fix-001/execution-evidence-003.json)。

这三次均未确认 Google 搜索成功或取得协议 close 双 true；各次 Runner 的 page destroy/store cleanup 和空 artifact base 是局部证据，Manager 退出单独记录，不能替代协议 cleanup。源码修改范围为 `NavigationCorrelation.swift`、`OwnedBrowserAutomationPage.swift` 和对应 correlation 测试；[cleanup 与身份链主审记录](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/navigation-fix-001/main-cleanup-chain-review.json) 保存的七个门禁文件保持不变。

第四版复用原 owned WebView、window 和 geometry 校验，普通路径及默认 URL 门禁保持原样；仅在私有持有的原生 policy action 路径允许精确匹配该 action 目标的候选 URL。main 的 [source review 004](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/navigation-fix-001/main-source-review-004.json) 和 [artifact review 004](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/navigation-fix-001/main-artifact-review-004.json) 记录了源码范围、七个门禁文件不变、9 项 artifact pins 和两层 strict 签名。受测 App 为 [Safarier.app](/Users/yingzhang/safarier-navfix-cb31162a82c6432e9fc4debe08d363be/Safarier.app)，未据此宣称该包已由 Finder 人工打开。

北京时间 **14:18:42–14:19:01** 的 004 轮实际记录 `finished reserve → adopt → currentAllowed=false/currentEqualsActionTarget=true → provisional reserve → same-native redirect confirm → commit/finish`，随后返回 `navigationFinished` 和 ready 状态。这次运行确认了原候选 URL 准入前检查的循环次序问题。main 实际查看 [form.png](/Users/yingzhang/safarier-navfix-cb31162a82c6432e9fc4debe08d363be/google-search-004/results/form.png)（SHA-256 `b2165bee1308cea034ad24ab140d5b6f118772ed750145e57e7e6bebf51fb04f`）：Google 显示异常流量页面及未勾选的 reCAPTCHA，并显示原始 `search?q=AI` URL；画面没有搜索结果，搜索结果未验收，也没有操作验证码或重试。见 [runtime review 004](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/navigation-fix-001/main-runtime-review-004.json) 和 [运行证据 004](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/navigation-fix-001/execution-evidence-004.json)。

004 的协议 close 返回 `cleaned=true` 和 `terminatedOwnedRunner=true`；Runner 原始记录为 page destroyed、store cleaned、`removedFiles=1`、`retainedFiles=0`、`directoryRemoved=true`，owned artifact base 为空。Manager 退出另行记录，不能替代这些证明。本轮沿原 AppleScript 显式搜索 URL 导航，没有验证原生鼠标、输入或 Enter 提交，也未扩大为通用 G1/G5、IME 或 wheel 验收。

## 可见观察：同一受控页面

双宏 internal testing 的 bound 页面在原 fixture 和 native input ready 后进入私有 `visibleObservation` 状态，显示原有的 owned window 与 WebView，保持原几何和目标；窗口保持 accessory、inactive、non-key/non-main、不能成为 key/main，并忽略物理鼠标。非内测后台路径与 wheel observer 保持隐藏，人工浏览沿原有显示逻辑。原 native engine、身份与 cleanup 七个门禁文件不变，没有增加持久化、期限变更或人工接管、暂停/恢复功能。见 [源码主审记录](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/visible-observation-001/main-source-review.json) 和 [产物主审记录](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/visible-observation-001/main-artifact-review-001.json)。本次受测 App 是 [Safarier.app](/Users/yingzhang/safarier-visible-2c6af0bc6fe845ecae39c831573281af/Safarier.app)。

北京时间 **14:37:15–14:37:44** 的 Selenium 定向测试中，Runner 验证同一 owned window 可见、inactive、非 key/main，目标和 viewport 保持；外部仅对该确切 window number 的元数据观察到 `onScreen=true`，不将元数据作为身份或路由依据。原 native 路径的 7 条 sequence 为 1–7；main 查看 [form.png](/Users/yingzhang/safarier-visible-2c6af0bc6fe845ecae39c831573281af/visible-input-001/results/form.png)，普通文本字段显示 `Safarier Test 123中!`，SHA-256 `7830999d1a491c812a0db62d0d5ec928e6433c95816933e8ecf1d3c5f10b4238`。协议 close 返回 `cleaned=true`、`terminatedOwnedRunner=true`；Runner 实际 page destroyed/store cleaned，`removedFiles=2`、`retainedFiles=0`、`directoryRemoved=true`，owned artifact base 为空。见 [运行主审](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/visible-observation-001/main-runtime-review-001.json)、[运行证据](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/visible-observation-001/execution-evidence-001.json) 和 [窗口元数据](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/visible-observation-001/window-metadata-001.json)。用户该轮原话：“看到窗口，操作其他 App 未受干扰”；这是仅限该次运行的主观反馈，见 [用户反馈](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/visible-observation-001/user-feedback-001.json)。用户要求的观察窗口已获本轮有限验证；会话结束自动关闭可见窗口，人工接管尚未实现。

14:31:57 的 [系统网络元数据](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/visible-observation-001/network-metadata.json) 记录 HTTP、HTTPS、SOCKS 代理标志为 true，PAC 为 false；这些标志不能证明 WKWebView 的实际出站路径或 Google 验证的原因。Google [官方说明](https://support.google.com/websearch/answer/86640?hl=zh-Hans)列出网络自动化流量及 VPN/共享网络等可能情况，不能据此断定本次原因或验证码会消失。此前 navigation-fix 004 的 CAPTCHA 结果保持历史记录。用户另反馈普通 Safari 或 Chrome 通常不会出现验证；这不是同一时刻受控对照，不能据此或上述代理标志认定原因。见 [用户反馈 002](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/visible-observation-001/user-feedback-002.json)。

可见观察的 **002 Google 轮**使用上述有效交付 App；main 核图为异常流量页面和未勾选 reCAPTCHA，没有搜索结果，query 未确认。原生导航、同一窗口可见、精确 window number 的 `onScreen=true` 元数据和真实 close 双 true 均通过定向核验。见 [运行主审 002](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/visible-observation-001/main-runtime-review-002.json)、[运行证据 002](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/visible-observation-001/execution-evidence-002.json) 和 [窗口元数据 002](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/visible-observation-001/window-metadata-002.json)。

**003 兼容性对照轮**于北京时间 14:46:40–14:46:59 使用单独实验 App；factory 只复用普通 factory 在引擎匹配时的 Safari application name，readback 为 `applicationNameConfigured=true`、`matchesEngine=true`、JavaScript true、persistent false。main 核图仍为异常流量页面及未勾选 reCAPTCHA，没有搜索结果，query 未确认；这一轮未观察到该单项改动带来 CAPTCHA 改善。原生导航、窗口可见及确切 window number 的 `onScreen=true`、协议 close 双 true 均通过；Runner 记录 destroyed/store cleaned、removed 1、retained 0、directory removed，owned artifact base 为空。见 [源码主审 002](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/visible-observation-001/main-source-review-002.json)、[运行主审 003](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/visible-observation-001/main-runtime-review-003.json)、[运行证据 003](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/visible-observation-001/execution-evidence-003.json) 和 [窗口元数据 003](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/visible-observation-001/window-metadata-003.json)。没有点击验证码或自动处理验证。

该实验的 factory 改动已恢复至本轮基线；实验 [App](/Users/yingzhang/safarier-visible-dc26a7f3fa764ec39a8d11ac4eed4aeb/Safarier.app) 保留为不可变证据，不是交付包或当前源码。有效交付仍为上面的 `safarier-visible-2c6af0bc6fe845ecae39c831573281af/Safarier.app`，对应可见 Selenium 原生输入和可见 Google 002 测试。有效代码变更限于 Page 可见观察及 SwiftHost 复用和 close proof，另同步本文档；非内测后台路径与 wheel observer 保持隐藏，人工浏览沿原有显示逻辑。当前窗口仅供观察，不能供用户点击 CAPTCHA；如需人工暂停、接管和恢复，须另行设计，不能以自动验证码处理替代。

## 用户本轮反馈

- 针对 004 轮 14:18:42–14:19:01 期间并行使用其他 App 是否受到干扰，用户原话：“当时在操作，未发现干扰”。这是仅限该轮的主观反馈，见 [原话收据](/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/navigation-fix-001/user-feedback-001.json)。

- 针对 10:15:25–10:16:05 期间是否在其他 App 使用键鼠及有无干扰，用户原话：“当时在操作，未发现干扰”。这是本次实际操作期间的有限主观反馈，不继承旧 fixture 反馈，不推广至长期或所有干扰场景。
- 用户报告自行打开管理界面并启动指定网页后，原话：“管理界面和网页均正常”。用户随后确认打开的是“之前已安装的 Safarier”，因此该网页与普通 UI 反馈属于已安装旧版，不计入 testing 包的真实网站验收。完整澄清问答见 `/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/user-feedback-003.json`；原反馈保持不变。

- 随后用户针对指定的原 testing 包 `/Users/yingzhang/safarier-testing-1be4abcbe9e443c58296eb913ba656e7/Safarier.app` 再次双击反馈“这次出现了管理界面”；这是原 testing 包重新打开的人工反馈，不等同修复包 Finder 首次打开或手工真实网站验收。

- 用户针对紧邻上下文所指的修复版交付 App 人工打开反馈原话：“打开正常”。按上下文归属修复版，不推断独立遥测、点击时间、手工真实网站或 AppleScript 已验证；收据见 `/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/normal-launch-debug-001/user-feedback-005.json`。

完整问题和原话收据：`/Volumes/RC500/dev/safarier/.build/formal-test-app-20261106-001/user-feedback-002.json`。此前 Selenium 与普通 UI 反馈收集阶段，未停止、代点或关闭用户可能仍在使用的 App/Runner。Google 轮次仅按 `user-authorization-001.json` 的明确授权退出那两个 Manager，未关闭其他 App/Runner。

## 默认目录权限观察

此前收口时 `~/Library/Application Support/Safarier Test`、其 `locks` 和 `profiles.json` 均不存在，这是历史 snapshot，不代表当前状态。后续诊断曾观察 root 和 locks 为 UID 501、0700、非 symlink，且当时 `profiles.json` 不存在。2026-11-06 10:55:36 +0800 再次只读 `lstat` 时，root 和 locks 为 UID 501、0700、非 symlink；`profiles.json` 已出现，UID 501、0600、普通文件、非 symlink。状态可随用户操作变化；没有读取 profile 字段、账号或凭据，也没有修改目录或权限。
