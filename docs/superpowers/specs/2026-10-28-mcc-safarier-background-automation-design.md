# MCC–Safarier 后台原生自动化正式设计

- 日期：2026-10-28；版本：v1。
- 状态：用户于 2026-10-28 确认本正式设计与实施计划；进入受安全门禁约束的执行阶段，**不是已实现功能清单**。
- 工作目录：`/Volumes/RC500/dev/safarier`；目标分支：`mcc-safarier`。
- Git 基线：`2f32d21248deaffd8c8c1152a39912aa46350c7e`；已有原生输入修复尚在工作区，不能只按 HEAD 推断能力。
- 设计初稿轮只新增设计与计划；当前执行状态以实施计划与验证报告为准。用户于 2026-10-28 明确要求继续功能代码后，可先开发不接入桌面操作的离线核心；G0/G1/G2 未满足前不开放实际控制入口或执行图形验证。提交、推送、安装或发布另行授权。
- 实施计划：`/Volumes/RC500/dev/safarier/docs/superpowers/plans/2026-10-28-mcc-safarier-background-automation.md`。

## 1. 目标与不可让步的约束

一个 `Safarier.app`，外部 AI/脚本通过 AppleScript 控制指定 Profile 的网页，用户同时正常使用其他 App 的鼠标、键盘与输入法。保留单 App 包、Manager 与每 Profile 独立 Runner 的结构；“一个 APP”不等于“一个进程”。

以下文本也是实施计划的全局约束：

- **C1**：禁止全局输入兜底：不投递全局 CGEvent，不移动/回移系统鼠标，不调用 System Events、辅助功能点击、全局按键或抢焦点重试。
- **C2**：禁止生产网页 JS 注入、DOM click/dispatchEvent、任意脚本执行或任意 selector 执行接口。
- **C3**：后台任务不得激活 Manager/Runner、设置真实 key window、隐藏/改变系统光标、改变全局修饰键、Secure Input 或用户输入法状态。
- **C4**：缺少已验证的输入能力、UI 逃逸拦截能力、目标身份或后台状态时明确拒绝；不把 unavailable/degraded 当作自动化成功。
- **C5**：复用 Profile、ProfileLock、代理、DataStore、RunnerLauncher 与原生桥；不增加第二套浏览器、独立常驻 daemon 或默认监听端口。
- **C6**：首版只控制专属后台 Runner 的单窗口/单 WebView；不接管已在运行的人工 Profile，不支持会话中自动切换前台。
- **C7**：临时按钮/页面活动状态必须有界收尾；光标写入保护允许仅在专属 Runner 内常驻至进程退出，不能宣称所有 hook 都在 close 时卸载。
- **C8**：代码与设计审查只由主代理执行；不交子代理 review。未经用户要求不提交、推送、合并、安装或发布。

“不干扰”是必须通过的产品门禁，而非对任意系统版本、任意网页的预先保证。系统首次 Apple Events 授权需要用户明确参与，应在单独的初始化阶段完成；不能承诺操作系统首次授权对话框也完全无打扰。

## 2. 已有源码与证据：保留什么、改变什么

| 已有实现 | 实际行为 | 本次决定 |
|---|---|---|
| `Sources/Safarier/main.swift`、`SafarierCore/ExecutableRole.swift` | 同一二进制区分 Manager GUI、Manager CLI、Runner；打包角色共用 Bundle 来源 | 保留角色，不另建 App 或 daemon；Apple Event 多实例接收身份必须单独验证 |
| `SafarierCore/Profile.swift`、`SafarierWorkspace.swift`、`ProfileLock.swift` | 元数据、Profile 启动、flock 单实例、Runner PID | 保留为身份/生命周期来源；PID 文件不是控制授权 |
| `SafarierCore/RunnerLaunchSpec.swift`、`RunnerLauncher.swift` | 语言/时区参数；Process 启动；stdin 当前为 null；stdout/stderr 写 Profile 日志 | 扩展显式后台模式与继承通道；普通启动默认行为不变 |
| `Sources/Safarier/RunnerMain.swift:17` | 先锁 Profile、代理/语言时区初始化，必要时 execv 自重启，再建浏览会话 | 自动化必须经过同一流程，不能跳过代理/数据隔离 |
| `ManagerGUI/ManagerApp.swift:72–91` | 默认 regular、didFinish 主动 activate、关最后窗口即退出 | 自动化冷启动必须先成为无窗口非激活宿主；用户主动打开仍显示原管理界面 |
| `Browser/BrowserSession.swift:59–104` | start、openWindow、openTab 都可能 makeKeyAndOrderFront；background tab 也会 makeKey 原窗口 | 把呈现方式变为明确策略，不把旧 background 参数误当安全后台模式 |
| `Browser/BrowserWindowController.swift:599–778` | window.open、新标签、JS 对话框、文件框、媒体权限、HTTP 认证等原生入口 | 在所属委托路径提前决策；后台路径不能显示 sheet 或另开窗口 |
| `Browser/BrowserViews.swift:143`、`DownloadsController.swift` | 原生 WebView、菜单、下载与访达打开入口 | 继续使用这些类；后台屏蔽系统菜单/下载等有外部副作用入口 |
| `SafarierWebKit/WebViewConfigurationFactory.swift:91–95` | 当前公开设置启用元素全屏 | 人工模式保留；自动化配置必须在 WebView 创建前禁用并回读 |
| `SafarierObjCSupport/SFRRuntime.m`、头文件第 74–91 行 | 已验证的页面逻辑活动、局部按钮状态、原生事件、鼠标完成栅栏、Runner 内光标保护 | 正式后端唯一底层路径，不再写第二套全局执行器 |
| `scripts/background-input-probe/NativeEvents.swift` | 目前还只是实际浏览类上的测试驱动 | 抽取为生产后端，测试改为调用同一后端；诊断 trace/stub 不进入正式驱动 |
| `scripts/build-app.sh` | 打包同一 App、Bundle ID `sh.safarier.app`；目前没有 sdef | 同步加入脚本词典与最早期非激活启动配置 |

MCC 的原生执行路径会使用全局输入，不能原样嵌入本方案。首版沿用其动作/取消的使用习惯，不依赖安装 MCC，不链接 Rust CLI，不动相邻 `chrome-control-cli` 工作区。

### 2.1 已有验证不是正式产品验收

证据：`/Volumes/RC500/dev/safarier/docs/verification/2026-10-28-background-pointer.md`。

- macOS `26.6.2 (25G83)`、arm64、WebKit `21624.5.1.11.3`；后台/遮挡/orderOut 各 3 轮，9 × 25 = 225 检查通过；原生检查 30 项通过。
- 只验证局部输入原语和特定宿主；未验证真实 Manager 冷启动、正式 AppleScript 路由、全部系统 UI 入口、最小化、跨 Space、多显示器或连续中文 IME。
- 最终矩阵观察到外部鼠标活动，但该组没有外部按键计数；不能声称它已证明真实持续打字不受影响。
- 最终矩阵来源、旧失败与无输入对照均保留。光标图像变化不能单独归因于本程序。
- 本轮再次运行 `swift package dump-package` 返回 1：当前 CLT 的 PackageDescription 链接 ABI 不匹配。正常 SwiftPM/XCTest 与正式打包仍是前置阻塞，不以手工编译探针代替。

### 2.2 工具链选择澄清与替代路线证据（2026-10-28）

用户同意先调查不安装完整 Xcode 的路线。**G0 要求的是配套且经过验证的编译/测试环境，不指定必须安装 Xcode.app。** 完整 Xcode 是获取一组配套组件的候选方式，不是后台输入方案的技术前提；不因查不到 Xcode.app 就断言无法编译。

- terra-worker 利用本机已有 public interface、命令级 VFS overlay 与独立缓存，成功解析未修改的原 manifest，编译并链接包含正式 main.swift 的原 Safarier 产品；主代理用另一组全新缓存独立复现，均 exit 0。没有运行产品、替换入口或移除测试目标。
- 这是针对本机不一致 interface 的诊断规避，不是默认 SwiftPM 已修复，也不等同受支持的通用工具链配置；主代理复查默认 dump-package 仍 exit 1。不能把临时 overlay 无条件纳入正式产品构建。
- 当前真实 XCTest 缺失，独立最小 import XCTest 编译失败；原有四个测试目标仍保留。跳过 XCTest、改成零测试成功或仅跑新增 Swift Testing 都不算通过原有回归。
- 因此 G0 仍 blocked；release/签名 App 打包与隔离图形全测尚未完成。任何下载/安装/全局修复需另获授权；不降低“不干扰输入”门禁。

详细证据：`/Volumes/RC500/dev/safarier/docs/verification/2026-10-28-automation-clt-alternative.md`。

## 3. 方案选择

| 方案 | 优缺点 | 结论 |
|---|---|---|
| A：AppleScript → Manager → 继承连接 → 专属 Runner → 原生后端 | 复用现有角色、无公开控制端口、不会误接管人工窗口；首版不能附着既有 Runner | **采用** |
| B：各 Runner 开本地监听服务，Manager 按 PID/路径发现 | 可附着已运行环境，但引入认证、陈旧注册、PID 复用和人工接管竞争 | 首版不做 |
| C：嵌入 MCC 全局输入或给网页派发 JS 事件 | 容易接通，但直接违反 C1/C2，也不能证明真实后台语义 | 禁止 |

单 App 内新增的协议/控制适配层是为已有 Manager 与 Runner 连接，不是另起一套管理器；现有 Profile/代理/浏览组件继续拥有原职责。

## 4. 完整调用链与进程边界

```text
外部 AppleScript（显式 launch；不 activate）
  → Safarier Manager 的 NSScriptCommand（薄 JSON 适配，异步返回）
  → AutomationManager：权限、Profile、请求去重、会话路由
  → socketpair 继承连接（Manager 持续持有；没有 listen/磁盘 endpoint）
  → 原有 RunnerMain：锁、代理、语言/时区、WebViewConfiguration
  → BrowserSession(.automationBackground)，唯一目标对象绑定
  → NativePageInput → SafarierObjCSupport → 目标 WebView 内部原生响应链
  ← 完成栅栏/结果/错误；绝不把排入队列等同网页业务完成
```

### 4.1 Manager 启动与人工界面

1. Bundle 最早期以 `LSUIElement=true` 启动；在明确人工打开之前，不创建管理窗口、不切 regular、不安装会抢焦点的窗口动作。
2. 用现有 `ManagerApp.swift` 的生命周期入口承接非激活启动。首选重构为单一 AppKit 生命周期，复用 `ManagerModel` 与 `SafarierAppView` 的 SwiftUI 内容，原菜单迁入唯一 `ManagerMenu`，删除被替代的 Scene/commands 启动代码，不能保留两套 Manager。
3. 支持的自动化冷启动脚本先执行 AppleScript `launch`，再发自定义命令，不执行 `activate`。在专门启动验证中确认 launch/open/reopen 事件顺序；未证明安全的隐式冷启动方式不列为支持路径。
4. 用户双击/明确 reopen 才切 regular 并显示管理窗口。脚本的 openSession、导航、截图、轮询不得走此路径。无法可靠判别的启动事件保持无窗口并拒绝，不自动“帮助打开”。
5. 管理窗口关闭时若仍有自动化会话，隐藏管理界面但保留 Manager；显式退出则取消所有自有会话。Manager 已被用户置于前台时，脚本不改变其现有焦点。
6. **多实例接收者门禁**：现有 Manager 与各 Runner 由同一 App 二进制启动，不能假定 `tell application id "sh.safarier.app"` 必然投递 Manager。必须在仅人工 Runner 存活、Manager + 多 Runner、Runner 被用户置前台、旧 App 副本存在的场景核对接收 PID/role/构建。capabilities 提供接收角色/Manager PID/构建标识，非 Manager 收到命令只能明确拒绝，不能启动第二个 Manager 或直接操作该 Runner。
7. 如果无法用已验证机制保证唯一 Manager 接收身份，G1 保持 blocked；可另提 App 包内独立身份的 Runner helper 方案，但它会影响签名/资源定位/跨进程窗口循环，必须先向用户解释并获批，不能本轮暗中新增 helper、公开监听服务或运行时伪造 Bundle ID。
8. 以上是 G1 启动门禁，尚无实现证据。若需要超出上述生命周期/菜单迁移的 UI 重构，暂停并另请用户批准。

### 4.2 Runner 与私有通道

- `RunnerLaunchSpec` 增加 `backgroundAutomation: Bool = false`，参数为 `--background-automation`；与 `--probe` 互斥。不传 session token、文字或凭据到 argv/environment。
- 复用 ProcessSpawning/RunnerLauncher，新增可选 `standardInput: FileHandle?`（默认 nil 仍使用 nullDevice）。Manager 创建 `socketpair(AF_UNIX, SOCK_STREAM)`，把子端作为 stdin；Runner 的 fd 0 是双向私有连接，stdout/stderr 仍为现有日志。
- 两端验证 socket 类型、framing 与启动握手；通道不是从用户可写路径重连，也没有公开服务。握手绑定 protocolVersion、Profile ID、Runner instance UUID、启动 nonce；nonce 只走继承连接。
- 原始描述符 close-on-exec；仅 Runner 所需 fd 0 跨原有语言跟随的 execv 保留，完成自重启后设 close-on-exec。现有子进程必须显式 stdin=null，验证 curl/sing-box 等不会继承该控制连接。
- I/O 使用非主线程读写、主线程执行 UI；设 `SO_NOSIGPIPE`，处理 partial read/write、EOF、消息上限、背压和异常帧。EOF 是取消信号，不重新发现或连接其它进程。
- Manager 每个会话持续持有连接；不按每条 AppleScript 命令断开，否则无法可靠清理按住状态。Manager 崩溃 → EOF → Runner 收尾并退出；重启 Manager 不接管旧连接。
- Profile 已锁且不是本 Manager 当前自有会话：`PROFILE_ALREADY_RUNNING`，不激活、不终止、不复用。锁检查竞争最终仍由 Runner 的 flock 裁决。

## 5. 授权、目标身份与所有权

- `Profile` 增加 `allowsBackgroundAutomation: Bool = false`，旧 JSON decode 默认 false；GUI 明确开启后方可 openSession。AppleScript 不提供修改该许可的命令。
- 首次 Apple Events/TCC 授权在用户主动设置阶段处理；正式后台执行不弹本 App 权限引导，不请求 System Events/辅助功能控制。
- sessionID 使用系统安全随机源生成 32 字节、base64url 编码，是内存中的 bearer capability；每次会话请求必须携带，日志只记不可逆短标识。可由同一已获 Apple Events 授权的工作流跨请求使用，不要求同一个 osascript PID。
- Manager 只接受同一登录用户的 Apple Event；读取系统给出的 sender audit 信息，不能拿请求 JSON 中的 UID/PID 当可信身份。拿不到可信 sender 身份就拒绝。
- 精确绑定 `TargetIdentity(profileID, runnerInstanceID, windowID, pageID)`；后两者由 Runner 为实际 controller/WebView 对象生成 UUID。页面导航不重新选目标；绝不用“当前前台窗口”、标题、索引或全局坐标找页面。
- 首版每个 Profile 一个会话、每个会话一个目标；同一会话的操作串行。`cancel` 优先处理而非排在长导航之后；不同 Runner 可并行。
- 配置许可在每次执行前重读；GUI 保存撤权时立即通知本 Manager 取消会话并关闭自有 Runner，不能只更新 UI 标签。外部直接改文件在下一条操作前发现，无后续操作时至迟受现有 30 秒 lease/5 秒 hold 上限约束，不声称提供跨进程文件修改的零延迟通知。原编辑器“下次启动生效”提示须说明自动化撤权是即时例外。

## 6. AppleScript 与 wire contract v1

### 6.1 薄脚本词典

`Contents/Resources/Safarier.sdef` 只暴露一个自定义入口，避免另做可变 KVC 对象树：

- 命令：`automation request <JSON text>`，返回 JSON text。
- Suite：`SFAu`；Event：`SFAu/requ`；实现类：`@objc(SFRAutomationRequestCommand)`。
- Info.plist：`NSAppleScriptEnabled=true`，`OSAScriptingDefinition=Safarier.sdef`。
- NSScriptCommand suspend/resume 配对处理异步请求，主线程不 semaphore.wait、不 spin runloop；异常、取消、超时均恰好返回一次。基础解析错误与运行错误也使用统一 JSON；系统拒绝 Apple Event 时保留系统错误，不伪造 JSON 成功。

仅作未来接口示例，当前 App 尚未提供此命令：

```applescript
with timeout of 45 seconds
    tell application id "sh.safarier.app"
        launch
        set replyJSON to automation request "{\"version\":1,\"requestID\":\"00000000-0000-4000-8000-000000000001\",\"action\":\"capabilities\",\"parameters\":{}}"
    end tell
end timeout
```

### 6.2 输入与输出

```json
{"version":1,"requestID":"00000000-0000-4000-8000-000000000002","action":"openSession","parameters":{"profileID":"00000000-0000-4000-8000-000000000003"}}
```

```json
{"version":1,"requestID":"00000000-0000-4000-8000-000000000004","sessionID":"example-not-a-real-token","action":"move","parameters":{"x":120,"y":80,"viewVersion":1}}
```

```json
{"version":1,"requestID":"00000000-0000-4000-8000-000000000004","status":"ok","effect":"nativeDelivered","result":{"sequence":1,"buttons":0,"viewVersion":1}}
```

```json
{"version":1,"requestID":"00000000-0000-4000-8000-000000000004","status":"error","error":{"code":"TARGET_CHANGED","retryable":false,"sideEffects":"none"}}
```

- 回执必须有 version/requestID/status；成功必须有 effect/result，失败必须有 error，二者互斥。除无法解析的 requestID 明确为 null 外，不适用的字段省略。
- UTF-8；单帧最多 65,536 字节；拒绝重复 JSON key、未知字段/动作、错误类型、非法 UUID、NaN/Infinity、过量文字及错误版本。IPC 使用 4 字节大端长度 + 同一 JSON envelope。
- `parameters` 根据 action 解码为强类型，不让 `[String: Any]` 沿生产调用链传递；未知 action 不能掉进任意 selector 或脚本执行。
- `capabilities` 与 openSession 不带 sessionID；其它动作必须带。openSession 只接受用户已许可且未运行的 Profile。
- 无法安全解析 requestID 的错误回执用 `requestID=null`，不回显原始错误值。已认证 session 内 requestID 是幂等键；在 30 秒 lease 内最多缓存 256 个完成回执，满时拒绝新操作，不通过淘汰旧键后重放动作。openSession 按可信调用者身份 + requestID 去重；相同键而 payload 不同返回 `REQUEST_ID_REUSED`，不能覆盖旧请求或执行新动作。响应丢失不能盲目重试点击。
- `effect` 区分 `sessionOpened`、`nativeDelivered`、`navigationFinished`、`snapshotWritten`、`stateRead`、`sessionClosed`；nativeDelivered 不是“表单提交成功”。
- 错误副作用分类：`none`（送入前拒绝）、`possible`（送入后无法确认）、`delivered`（已送入、后续受阻）。失败不承诺回滚网页业务操作。

### 6.3 首版动作集合

| action | parameters | 语义 |
|---|---|---|
| capabilities | `{}` | 不启动 Runner、不装输入 hook；报告 backend/UI policy/cold launch 的 active/unavailable/unverified 与版本 |
| openSession | `profileID` | 启动专属后台 Runner，完成代理/能力/目标握手，返回 sessionID、TargetIdentity、viewport、viewVersion |
| getState | `{}` | 读原生 URL/加载/目标/会话状态；不返回 DOM、正文或密码 |
| navigate | `url` | 仅 http/https；等待本目标导航 didFinish，超时停止该加载并回错误；失败不转直连 |
| screenshot | `{}` | 自有 WebView 的原生快照，返回私有 PNG 路径与坐标元数据，不截用户桌面 |
| move | `x,y,viewVersion` | 无按住为 hover；按住时为目标内原生 drag |
| mouseDown / mouseUp | `x,y,viewVersion` | 仅左键；非法状态/越界先拒绝，down 有绝对 5 秒上限 |
| click | `x,y,viewVersion,count` | count 只允许 1/2，原子 down/up；已有按住则拒绝 |
| scroll | `x,y,viewVersion,deltaX,deltaY` | delta 为有限 point 值，每轴绝对值不超过 1,000；只送目标 responder |
| insertText | `text` | UTF-8 最多 16,384 字节；目标内文本输入客户端插入，不切换系统输入法 |
| key | `name,shift` | Backspace/Delete/Enter/Tab/Escape/Left/Right/Up/Down/Home/End；shift 仅选择/Tab；不开放 Command/Control/Option 组合或持久修饰键 |
| cancel / closeSession | `{}` | 停止队列、收尾并关闭自有目标/Runner；已关闭的同一会话返回稳定关闭回执 |

不提供右键、原生菜单选择、系统拖放、全局快捷键、任意 eval、文件上传选择器操作、窗口激活或前台 fallback。原生 Unicode 插入不等价于持续 IME 组词模拟；用户在其它 App 的 IME 不应受影响。

## 7. 坐标、时序与按住状态

### 7.1 坐标契约

- x/y 为 WebView 可见内容区域左上角起算的 **AppKit logical points**，不是屏幕坐标，不默认等于 CSS px；转换由后端处理 flipped view。
- screenshot 返回 `viewportWidthPoints`、`viewportHeightPoints`、`pixelWidth`、`pixelHeight`、`scaleX`、`scaleY`、`pageZoom`、`viewVersion`。图像坐标转换：`x = imageX / scaleX`，`y = imageY / scaleY`。
- 必须命中实际 WebView 子树；`0 ≤ x < width`、`0 ≤ y < height`，不自动裁剪越界坐标。窗口缩放/移动、原生 pageZoom 改变、导航开始使 viewVersion 失效并取消按住。
- viewVersion 只保证已知原生几何/导航代际，不保证发现所有网页自身异步 DOM/layout/动画变化。动态页面可能需要重新截图；不能以该 token 宣称点击必定命中特定语义元素。
- 首版不提供 viewport resize 命令，不切换其它窗口/标签。页面生成新视图被 UI policy 拒绝，不能偷偷绑定到新对象。

### 7.2 状态机与完成标准

```text
opening → ready → held → ready
             ↘ blocked/stopping → closed
opening/ready/held -- EOF/lease/target change/permission revoke --> stopping
```

- AppKit 操作串行主线程执行；按钮状态保存于会话，查询替换只包住同步原生调用，不横跨 await。不让逻辑 pressedMouseButtons 泄漏到其它线程/进程。
- hover 的页面活动上下文与目标绑定；原生动作等待已检查签名的 pending-mouse completion。当前版本没有已验证的 pending-key selector，不编造键盘完成栅栏或固定 sleep 成功。
- `insertText`/`key` 回执只承诺原生 responder 调用已完成；网页最终值/业务效果交给截图或调用方后置条件检查。
- 时间预算：启动/导航各 30 秒；普通动作/截图各 5 秒；空闲 lease 30 秒；单次按住绝对 5 秒（普通命令不能无限续命）；收尾预算 2 秒。使用 monotonic clock，lease 仅由通过鉴权的有效会话操作续期。
- blocked 状态仅允许 getState、screenshot、cancel、closeSession；其它动作返回 `SESSION_BLOCKED`。没有隐式 resume，需关闭后重新建立会话。held 时发生阻断先按第 7.3 节收尾，必要时直接 closed。
- 不同会话/关闭后的回调使用 epoch 检查；迟到回调不能恢复活动状态或重复发送回执。

### 7.3 收尾不能顺便“补一次点击”

- 正常 mouseUp 是用户请求的完整操作；取消/EOF/超时不是用户请求的 mouseUp。
- 优先使用经过验证的本地取消机制。**不得在取消时补发可能触发 click/drop 的 mouseUp 来假装恢复成功**。
- 本地取消不能被证明无额外点击/拖放副作用时，停止送入，恢复本进程临时查询，销毁专属 WebView/窗口并退出该自有 Runner；进程退出清除剩余本地状态。已发生的 down 等业务副作用如实报 possible/delivered，不承诺回滚。
- 收尾失败将会话永久标为 closed/unavailable；只对本次握手绑定且身份仍匹配的子进程做有界退出/必要终止，不按进程名、旧 PID 文件或扫描结果杀进程。

## 8. UI 逃逸门禁：必须在展示前拦截

`BackgroundPagePolicy` 是显式执行策略，人工模式继续现有 Safari 式行为；自动化模式允许为安全而禁用部分原生特征，必须在 capability 报告中说明，不伪装为与人工模式完全一致。

| 入口 | 后台决定 | 必须检查的位置/证据 |
|---|---|---|
| start/openWindow/openTab/reopen/循环窗口 | 专属窗口初始 orderOut、不可成为 key/main、物理鼠标穿透；不切 Space、不排序前置 | BrowserSession / BrowserWindowController 的调用前策略，真实 WindowServer 状态复核 |
| target=_blank、window.open、window.close | 新视图返回 nil 并记录 INTERACTION_REQUIRED；关闭目标终止会话 | createWebViewWith / webViewDidClose，不新建后再藏回去 |
| alert/confirm/prompt/beforeunload | 不展示；完成回调一次，confirm=false、prompt=nil；会话暂停并报告 | 所有原有 JS UI delegates；补核 beforeunload 路径 |
| 文件/目录选择、保存、打印、原生分享、下载 | 取消并报告；不显示 NSOpenPanel/NSSavePanel，不写默认 Downloads，不开访达 | runOpenPanel、导航 download、WKDownload 及应用动作路径 |
| 摄像头/麦克风、定位、通知、屏幕捕获、剪贴板读取 | 拒绝；不触发操作系统首次授权 | 原生 permission delegates/配置与运行时桥的核验矩阵 |
| 全屏、视频全屏、PiP、pointer lock | 创建 WebView 前禁止并回读；请求时拒绝 | 公开 fullscreen preference + 已验证原生能力；不能只处理全屏之后的通知 |
| `<select>`/日期/颜色/自动补全等原生 popup、右键/长按/链接预览 | 不显示平台菜单/弹层；CSS 页面内部下拉/hover 正常 | BrowserWebView + WebKit 原生 UI hooks；willOpenMenu 单独不算可靠前置拦截 |
| HTML drag/drop、跨 App 拖放 | 禁止 OS drag session；只允许已验证不会起系统拖放的页面内 range/text/custom-pointer drag | 原生 drag-source 入口与能力回读/负例验证 |
| HTTP 页面认证、客户端证书、WebAuthn/Passkey/Apple Pay、外部协议 | 取消/拒绝并报告；不拉起系统面板/其它 App | challenge / decidePolicyFor / 已验证的原生 API feature gate；绑定代理自动认证保持原规则 |
| 有声自动播放/通知声 | 后台配置禁音/禁自动播放并核验；不能因 click 获得用户手势后突然响铃 | 音视频配置及目标 WebView 的静音能力；不修改系统音量 |

**G2 是完整 capability bundle，而不是仅验证 hover：** 针对已验证构建，列明每一入口的公开/私有方法、编码、设置回读和真实负例结果。目标 SDK 的公开 WKUIDelegate 不覆盖所有上述入口；上游源码只用于定位，不能视为当前机器已支持。某个危险入口无法提前封住，就不启用该构建的通用页面输入，返回 `UI_POLICY_UNAVAILABLE`；不得把支持列表写上便宣称已保护。

首次尝试危险 UI 入口的真实验证应在可丢弃的隔离 macOS 图形会话/VM 中完成，且构建匹配。未准备这样的环境时该门禁标记 blocked，不在用户当前桌面冒险点击后再“抢回来”。本轮不会创建系统用户/VM、修改 TCC 或运行这些用例。

## 9. 错误、安全日志与截图数据

错误码至少覆盖：`INVALID_REQUEST`、`UNSUPPORTED_PROTOCOL`、`UNAUTHORIZED`、`PROFILE_NOT_ALLOWED`、`PROFILE_ALREADY_RUNNING`、`SESSION_NOT_FOUND`、`SESSION_EXPIRED`、`SESSION_BUSY`、`SESSION_BLOCKED`、`REQUEST_ID_REUSED`、`REPLAY_WINDOW_FULL`、`BACKEND_UNAVAILABLE`、`BACKGROUND_LAUNCH_UNVERIFIED`、`UI_POLICY_UNAVAILABLE`、`INTERACTION_REQUIRED`、`TARGET_CHANGED`、`INVALID_POINTER_STATE`、`OUT_OF_BOUNDS`、`TIMEOUT`、`CANCELLED`、`RUNNER_EXITED`、`INDETERMINATE_RESULT`。

- 严禁记录输入文字、密码、sessionID、完整 URL 的 query/fragment、Apple Event 原文、网页正文、代理凭据。日志只含 requestID、动作名、脱敏会话标识、状态码与耗时。
- 截图必须显式请求；不自动在错误时截屏。仅写 `SAFARIER_HOME/automation-artifacts/<session-hash>/` 下本进程创建的非符号链接目录，目录 0700、文件 0600，随机文件名 + 原子创建；不接受调用方文件路径。
- 快照最大单边 4,096 像素、PNG 最大 32 MiB；超限拒绝，不静默改变坐标比例。每会话最多 8 份；满后拒绝新快照；默认 close/lease 到期删除，最迟 10 分钟清理。调用方需要留存时先自行复制。
- 清理仅操作本次生成并登记的对象/文件；历史未知目录不递归盲删。sessionID 不进文件名。
- 生产不全局监听/拦截/重放用户键鼠。验收的独立观测器只统计硬件事件数量/状态，不保存外部按键内容；测试假页面可保存自己的确定性 fixture 值。

## 10. 验收门禁与停止条件

| 门禁 | 放行要求 | 失败后行为 |
|---|---|---|
| G0 正式工具链 | 匹配且可复现的工具链（不限定完整 Xcode）；dump-package、原 swift test、release build、原打包脚本/签名可运行；不改系统 SDK、不删原断言 | 阻塞正式产品构建；原探针仅保留诊断价值 |
| G1 冷/热启动 | 显式 launch + 请求、Manager 已运行、多 Runner 接收身份、人工双击/reopen 各重复 3 轮；后台无窗口/激活/key/Dock 变化，人工 GUI/菜单仍正确 | 不开放外部自动化入口 |
| G2 UI policy | 第 8 节每条都有前置拦截/回读与隔离桌面负例；未知版本、坏签名和 hook 冲突拒绝 | 不对普通网页启用输入；绝不全局兜底 |
| G3 目标/生命周期 | 锁竞争、已有人工 Profile、EOF、Manager/Runner 崩溃、超时、撤权、迟到回调、请求重放全部覆盖 | 会话关闭、只清自有资源 |
| G4 原生与页面动作 | 保留 30 项原生检查、9×25 原矩阵；正式入口完成同类 hover/down/drag/up/Unicode/password/scroll/截图 | 不用测试专用路径冒充正式入口 |
| G5 不干扰与人工回归 | 正式入口 background/occluded/orderOut 各 3 轮；外部受控前台编辑器和真实用户活动都检查，无错字/漏字/焦点/光标/IME/secure input 干扰；人工 Safarier 正常 | 不交付、保留失败证据 |

**执行环境边界：原仓库完整 `swift test` 也包含会显示/激活窗口的 AppKit 测试，必须在隔离图形环境执行。当前工作桌面只做编译、无 UI 的纯逻辑测试及文档检查；不能因命令叫单元测试就默认无干扰。**

G5 先在隔离图形桌面把另一 App 的文字接收、修饰键、输入法与光标状态做可重复对照；再由用户在日常使用中做补充验收。没有真实输入时明确记“未覆盖”，不强迫用户停用鼠标，也不向用户当前前台应用合成全局按键制造测试数据。只对测试创建的进程/临时 Profile 收尾，不碰真实账号或现有业务窗口。

一次绿测不放行；旧失败、无输入对照和源文件/构建标识一起保留。多显示器、最小化、其它 Space、其它 WebKit 版本不在首版支持范围；不能静默展开能力白名单。

## 11. 实施顺序与边界

1. G0 工具链定位与可复现基线，G1 最小非激活启动验证，G2 原生安全能力矩阵；任一阻塞先报告，不对当前桌面试错。
2. 协议、Profile opt-in、继承通道、原有 Runner 的后台生命周期。
3. 抽取原生驱动、状态机、取消/清理、截图与回执。
4. AppleScript/打包接入，只在前面安全门禁通过后允许实际输入。
5. 正式调用链重复验证与主代理 review；安装/提交/推送/发布另行授权。

本设计首版不包括：附着人工窗口、跨标签/多窗口路由、系统文件框操作、HTML 系统拖放、原生菜单选择、任意网页读取 API、连续 IME 合成、远程网络服务或全面替代 MCC。

## 12. 设计依据与核验来源

本地源码与已有报告为事实来源；2026-10-28 核对的 Apple 文档/系统 SDK 只证明接口定义，不证明当前设计已运行：

- AppleScript Language Guide 的 launch：启动而不隐含 run；正式冷启动仍需 G1 验证。`https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/reference/ASLR_cmds.html`
- Cocoa Scripting 的 sdef/命令类模型。`https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ScriptableCocoaApplications/SApps_creating_sdef/SAppsCreateSdef.html`
- Foundation `NSScriptCommand.h` 第 87–97 行：appleEvent descriptor 生命周期与 suspend/resume 配对；实现时只复制所需 descriptor 信息。
- 本机 `WKUIDelegate.h`、`WKPreferences.h`、`WKWebViewConfiguration.h`：公开权限回调与 isElementFullscreenEnabled；不包含所有危险 UI 的完整控制。
- WebKit 上游 `Source/WebKit/UIProcess/API/Cocoa/WKUIDelegatePrivate.h`、`WKPreferencesPrivate.h`：只作能力研究索引，实施前核验系统构建/类型编码，不直接依赖 main 分支的 ABI。

## 13. 用户要求继续功能代码后的实施顺序澄清（2026-10-28）

不再以缺少 XCTest 为由阻塞所有源码开发：先实施原设计第 6 节协议、Profile 授权模型和第 4.2 节纯私有通信通道。它们只依赖 Foundation/POSIX，不挂接 Manager、Runner 启动或页面输入；授权默认 false。由 terra-worker 实现、主代理 review。

新增独立纯逻辑校验执行真实生产核心代码，并保留相应 XCTest 测试；独立校验不替代旧测试、不伪造 XCTest、不宣称全量回归通过。XCTest/GUI/正式打包门禁维持未通过，实际窗口/输入入口继续关闭；此顺序调整不是允许全局输入或降低 UI 安全策略。

### 首批离线核心落地结果

第 13 节授权的协议/幂等/Profile 许可和纯 socketpair 通道代码已落地。外部 AppleScript 命令、Manager 路由、Runner 启动、窗口/页面输入均未接入；旧正常 App 呈现路径未改，不把 Core 编译/校验成功说成后台产品可用。主代理联合校验与已修复回归见 `/Volumes/RC500/dev/safarier/docs/verification/2026-10-28-automation-core-implementation.md`。

## 14. 第二批受控启动/RPC落地边界（2026-10-28）

原启动器增加显式受控 stdin 能力，保留普通 API；Core client 与 typed wire/nonce-PID-instance-Profile 握手已由 Foundation 子进程验证。实际 Runner 新背景模式在 Profile/锁检查后、代理/WebKit/NSApplication 之前进入 serveUnavailable：仅能力查询成功，所有页面操作拒绝，不会落入旧 session.start。

这是尚不可操作页面的安全 bootstrap，不是通过了完整 Profile 代理/语言时区重启后的原生后台引擎接入；后续必须沿原初始化流程接入验证过的后端，不能只把 unavailable 改成 active。nonce/PID 一致性也不等于 Apple Event caller 授权或代码签名认证。

主代理独立进程/组合/编译证据及未通过门禁见 `/Volumes/RC500/dev/safarier/docs/verification/2026-10-28-controlled-runner-rpc.md`。


## 15. 第三批候选生命周期与脚本适配落地边界（2026-10-28）

旧 SwiftUI App/Scene 启动所有者已被单一 AppKit 延迟宿主替换，复用原 ManagerModel/SafarierAppView 与业务菜单动作。新增纯启动 reducer、当前 Apple Event sender 属性快照、只读能力服务、一次回复协调及真实 NSScriptCommand 子类。关闭人工窗口/显式 quit 对自有 pending 请求执行有界排空/取消；没有第二个 Manager 或全局输入路径。

这批是用户要求持续开发后的候选代码，不是 G1 已通过：实际系统事件顺序、多实例 Manager 唯一性、系统授权和 GUI/焦点均未执行验收。默认打包不启用脚本词典；仅显式 candidate 元数据装配，后端仍 unavailable，页面操作仍一律拒绝。被动 descriptor 和纯 reducer 测试不能替代 OS caller 身份或真实窗口行为验证。

主代理独立组合回归、并发/迟到/取消反例、metadata/sdef、正式产品编译和剩余门禁见 `/Volumes/RC500/dev/safarier/docs/verification/2026-10-28-manager-script-entry.md`。G0/G1/G2 未通过前不得因源码完成而开启页面控制；后续沿原计划实现目标授权、UI 逃逸能力和会话/原生驱动安全接入。


## 16. 第四批策略/会话核心落地边界（2026-10-29）

UI 策略和完整能力记录模型位于 Core，供原配置工厂与后续原 App 拥有者共用；人工模式继续原逻辑，显式后台配置当前在创建任何 WebKit 配置/数据存储及凭据访问前硬拒绝。53 项真实能力证据仍全部 unverified，不能由合成完整记录放行 G2。

新增 SessionMachine 只产生分派/自身目标销毁等意图，复用原协议/重放/token/target/viewport/limits。操作及清理回执均绑定每会话 instance/epoch，终态释放活跃 payload，稳定 close/cancel 回执使用有界身份元数据而不伪造时钟。没有真实定时器、持久权限重读、对象绑定、进程控制或 native 输入接线；纯 reducer 的期限不是实际收尾时间保证。

全部实现由 Terra worker 完成、主代理全部复核。三轮联合与独立反例、真实工厂的无 GUI 早拒绝及完整剩余门禁见 `/Volumes/RC500/dev/safarier/docs/verification/2026-10-29-background-policy-session-core.md`；逐项缺失的真实 UI 证据见同日矩阵。G0/G1/G2、脚本默认开关与 unavailable 页面服务保持不放行。


## 17. 第五批原 UI 边界/异步 owner 落地边界（2026-10-29）

原配置 Output 的只读模式传递到 BrowserSession，原页面委托与 App UI 路径在展示/下载/认证/窗口副作用前拒绝；人工路径保持原逻辑。通用 helper 仍是同一个 Core policy，不增加第二套浏览器。当前后台工厂保持 UI_POLICY_UNAVAILABLE，53 项真实能力仍未验证。

RunnerAutomationController 是消费原 machine effects 的异步 MainActor owner，注入事实/动作/cleanup，驱动 monotonic deadline，处理取消、跨调用路由、失效 timer 和有界额度。事实最后复核后到 sink 的原子本地检查不等于跨进程磁盘授权原子化；native sink 仍需同步核验实际目标并遵守后续取消。明确的调度器失效事件替代伪造时间；有界回执与一次 cleanup 尝试都不是实际进程已退出的证明。

本批未装配 shipping Runner/AppleScript 服务、未创建背景窗口或执行 native 输入，未运行真实 GUI。主代理全部 review 与三轮独立证据、未通过门禁见 `/Volumes/RC500/dev/safarier/docs/verification/2026-10-29-background-ui-controller.md`。后续仍须唯一 native driver、真实对象/进程绑定及隔离图形 G1/G2 验收，不能删除拒绝分支当作完成。


## 18. 第六批 native 抽取/私有截图存储边界（2026-10-29）

NativeEvents 已变为 probe 适配器，真实事件路径仅在 NativePageInput 中存在；普通构造在建立 lease 前硬拒绝，诊断入口/trace 仅条件编译。取消不补 mouseUp，held/未知/未完成工作要求自身目标销毁。实际 native 输入、截图像素及销毁后的 click/drop 仍未验收，不把 Window.close 视为完整 teardown 证明。

内存快照与 Core 私有文件存储分离。SnapshotStore 仅接可信拥有者提供的 base，使用 fd/identity/exclusive/no-follow/ACL/权限/有限额度与 TTL，仅清登记匹配文件，不输出任意路径；不能承诺任意同UID敌手与公开filepath之间的完全原子性。未来绑定必须固定到 workspace automation-artifacts、使用非MainActor存储I/O及可靠owner cleanup/tick。

完整源码/诊断编译、正常 admission 和三轮无GUI/POSIX验证及剩余门禁见 `/Volumes/RC500/dev/safarier/docs/verification/2026-10-29-native-input-snapshot-store.md`。G0/G1/G2、shipping入口和页面服务保持关闭，未执行真实App/probe/AppleEvents或native输入。
