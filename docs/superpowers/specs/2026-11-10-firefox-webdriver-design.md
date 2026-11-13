# Firefox 标准协议输入后端

状态：待审阅的设计稿；macOS、Windows 与 Ubuntu 的 Firefox 后端均尚未实现或通过实机验收。
日期：2026-11-10；2026-11-13 按用户要求扩展 Ubuntu 22.04。本文不指定发布版本，也不包含提交、推送、安装或远端部署授权。

本分支另设用户已授权实现的 [Docker 虚拟桌面目标](2026-11-13-mcc-docker-design.md)，允许专属容器内的 Xvfb/Openbox 环境；它与本稿普通桌面矩阵分别验收，不据此标记原生三平台完整交付。

> 2026-11-13 后续决定：Docker 目标已按用户要求改为普通 Firefox + X11 系统事件，不再使用本稿 WebDriver 方案；以 Docker 设计和使用指南为准。本文保留为原普通桌面方案的历史设计。

## 1. 目标与已确认约束

在现有 mcc 中增加 macOS、Windows 与 Ubuntu 22.04 同步交付的官方 Firefox 网页控制后端，以标准 WebDriver Actions 提供连续鼠标移动、悬停、拖拽、左右/中键、双击、键鼠组合及滚动。保留现有 Chrome 和通用 macOS 窗口控制。

用户已明确：不得通过执行网页 JavaScript 模拟鼠标操作。实现必须满足：

- 网页输入只经 WebDriver Actions 执行；原生窗口输入通过 macOS 现有链路、Windows 原生适配器或 Ubuntu X11 原生适配器执行，后端在连接建立时确定。
- 不调用 executeScript/executeAsyncScript、BiDi script.evaluate/script.callFunction、dispatchEvent、HTMLElement.click 等脚本接口实现输入；首期适配器不开放脚本执行接口，包括只读脚本。
- 不以 JS、AX 点击或另一输入后端作为失败后的自动降级手段。
- Rust 直接调用 geckodriver；无需新增 Node/Python 常驻服务、浏览器扩展或 Selenium Server。
- code review 由主 agent 执行。实现前必须继续追踪受影响的既有调用链，不能另建一套绕过现有门禁的执行器。

“标准输入”指浏览器级模拟输入，不承诺物理设备身份、移动系统光标、固定事件采样率、绕过站点自动化识别或保证外部协议唤醒成功。要求桌面光标实际移动时，仍选原生后端。

## 2. 现有实现与复用边界

当前源码基线观察：

| 模块 | 已有职责 | 本次设计的扩展点 |
| --- | --- | --- |
| `src/args.rs`、`src/execution.rs` | CLI、请求预处理、配置及本地/远端分派 | 新 Firefox 命令与能力检查 |
| `src/service.rs` | 单个连接、窗口身份、帧注册、动作与 Jev 调度 | 显式区分原生连接和 Firefox 会话连接 |
| `src/daemon.rs` | owner、操作预留、取消、Host 接管 | 将新动作纳入原有输入分类与串行控制 |
| `src/remote/*` | WSS、token、消息白名单、sequence、回执与恢复 | 新能力协商及请求字段校验 |
| `src/target.rs`、`src/jev.rs` | OCR ID/文字候选、模型选择、本地解析坐标 | 复用模型协议与选择逻辑 |
| `swift/Input.swift`、`swift/CursorMotion.swift` | CGEvent、点击前轨迹、暂停与焦点检查 | 保留原生输入；提取可复用门禁能力，不伪造原生输入回执 |
| `src/config.rs` | 本地配置与模型配置 | Firefox 配置独立于 models.toml |
| `src/runtime.rs`、`src/private_files.rs`、`src/remote/credentials.rs` | Unix socket、私有文件及凭据原子操作；部分文件操作已有 Linux 分支 | Ubuntu 复用已有 Unix/Linux 实现，补齐平台身份检查，不另建 runtime |
| `build.sh`、`install.sh` | macOS 构建、Swift helper、安装及签名校验 | 按平台扩展构建和安装契约；Ubuntu 不执行 Swift/Xcode/codesign |

现有 click 已投递 mouseMoved 并执行连续轨迹，但仅有 click/scroll/type/press 等有限输入；连接、截图和门禁目前以原生窗口为中心。Firefox 接入不是替换 bundle ID，也不能仅加一个 HTTP 调用。

当前 `src/execution.rs` 仍明确拒绝非 macOS 本地/Host 桌面请求；`src/daemon.rs` 的进程身份和 socket peer 校验也仅实现 macOS 分支。已有 Linux 文件操作分支不代表 Ubuntu 自动化已经可用，不能仅删除平台判断后宣称支持。

## 3. 方案选择与首期范围

选择官方 Firefox + geckodriver：HTTP WebDriver 负责会话和 Actions；BiDi 仅按已验证能力用于导航/上下文事件及视口观察。不同时维护两种 Actions 执行实现。

直接使用 BiDi 执行全部输入可减少协议种类，但首期需要额外处理实现兼容；留作后续替换适配层的选项。Playwright Firefox 依赖补丁浏览器，不用于接管官方 Firefox。单纯扩展 CGEvent 能补齐桌面动作，但不提供标准浏览器会话，因此保留为现有后端。

首期包括：

- macOS 14+、Windows 11 x64 与 Ubuntu 22.04 LTS x86_64 上有界面、mcc 管理的 Firefox 实例及专用持久化 profile；三平台属于同一首期交付，Windows 与 Ubuntu 不延后为二期。
- Ubuntu 首期桌面固定为发行版自带的 GNOME 42 + Xorg（登录界面选择 Ubuntu on Xorg），采用 Mozilla 官方非 Snap/Flatpak Firefox。原生 Wayland 会话及其中的 XWayland 窗口不在支持范围，不能因存在 `DISPLAY` 就认定支持。
- 三平台本机 OCR、CLI、daemon、Host/client、窗口身份/焦点检查及可见的暂停/取消控制；Windows、Ubuntu 均不依赖 Swift 或 macOS helper。
- 一个连接绑定一个 WebDriver session、一个顶层 browsing context，以及可验证的原生窗口身份。
- 视口截图/OCR/Jev 选 ID、坐标动作、完整的受限键鼠动作序列。
- 本地与现有远端 WSS 调用，以及暂停、取消、断线和进程退出处理。
- 原生微信授权窗与 Firefox 页面之间的显式切换验收。

首期不包括：任意已运行 Firefox 的接管、后台/无头输入、多窗口并行控制、跨应用拖拽、任意 JavaScript、DOM 查询公共接口、文件上传/下载工作流。普通网页内 HTML5 拖放单独验收，不能从 pointer 动作成功推断其成功。

Windows ARM64、Windows Server、Ubuntu ARM64、其他 Ubuntu 版本/桌面环境及其他 Linux 发行版不在首期支持矩阵；Ubuntu 的 SSH X11 转发、Xvfb、容器内桌面与远程桌面会话也不进入首期验收范围。协议可运行不等于完整桌面门禁可交付。

## 4. 架构与连接生命周期

```text
Agent → CLI / 现有 WSS → owner/sequence/暂停门禁 → Service
                                                   ├─ native → macOS Swift/CGEvent、Windows 或 Ubuntu X11 原生适配器
                                                   └─ firefox-webdriver → geckodriver → Firefox
```

新增一个边界明确的 Firefox 适配模块，负责进程、协议编码、会话、能力和错误映射。Service 保留授权、连接和业务动作调度。禁止将 geckodriver 暴露为任意 URL/路径的 HTTP 转发代理。

生命周期：启动 owned driver → 创建会话 → 验证浏览器版本与能力 → 绑定目标上下文和原生窗口 → observe → 输入 → observe 验证结果 → 释放输入并关闭 owned session/process。

- 建立连接时记录 backend、session/context、Firefox PID、windowId、profile 和 owner。不能凭标题猜窗口对应关系；无法证明映射时启动失败。
- 保留现有单连接模型；不借本功能加入多会话调度平台。
- 关闭当前目标标签页、会话失效或窗口身份变化时停止输入；不自动转到其他标签页。
- 新窗口/弹窗返回可观察信息，由显式选择操作绑定；禁止默认选择“最新窗口”。
- profile 锁定时返回占用错误，不强制解锁、不终止个人 Firefox。
- disconnect 在确认释放输入后删除 owned WebDriver session，允许关闭其管理的 Firefox；保留 profile 数据。禁止停止其他 owner 的进程。

## 5. 拟议 CLI 与配置

以下是待实现的接口契约，不是当前可执行命令：

```sh
mcc firefox start --profile mcc --url https://example.com/
mcc observe --connection <id>
mcc move --connection <id> --frame <frame-id> --x 240 --y 180 --duration-ms 300
mcc hover --connection <id> --frame <frame-id> --x 240 --y 180 --duration-ms 500
mcc drag --connection <id> --frame <frame-id> --from-x 120 --from-y 160 --to-x 420 --to-y 320 --duration-ms 600
mcc click --connection <id> --frame <frame-id> --x 240 --y 180 --button right
mcc click --connection <id> --frame <frame-id> --x 240 --y 180 --modifiers shift,meta
mcc actions --connection <id> --frame <frame-id> --file ./actions.json
```

原生授权交接接口拟定为 `mcc firefox suspend --connection <id>`（返回 owner 绑定的一次性交接句柄）及 `mcc firefox resume --handoff <handle>`（原生连接已断开后恢复并返回新 connectionId）。句柄不包含 Cookie、profile 内容或可供外部直连的 driver 端点；远端仍经现有认证链路。

通用命令根据连接 backend 分派，不通过命令参数临时切换。现有原生命令含义不变；未实现的动作/按钮返回不支持，不暗中扩大原生后端功能。move 是移到目标的持续时间，hover 是移动到目标后停留的时间；完整路径使用 actions。

新增本地 `mcc --config firefox` 配置入口：enabled（默认 false）、Firefox/geckodriver 可执行文件绝对路径、默认 profile 名、profile 根目录。profile 名只解析到受管理目录，不接受路径穿越。默认根目录：

| 平台 | Firefox profile 根目录 |
| --- | --- |
| macOS | `~/Applications/MCC/Profiles/Firefox/` |
| Windows | `%LOCALAPPDATA%\MCC\Profiles\Firefox\` |
| Ubuntu 22.04 | `$XDG_DATA_HOME/mcc/profiles/firefox/`；未设置或为空时为 `~/.local/share/mcc/profiles/firefox/` |

macOS 与 Ubuntu 使用当前用户私有目录权限；Ubuntu 目录为 0700，mcc 自建的敏感配置/状态文件为 0600。Windows 使用当前用户 ACL，路径由系统 Known Folder API 解析。路径在程序内解析，不依赖 shell 展开；Ubuntu 的 XDG_DATA_HOME 非空时必须是绝对路径，否则配置校验失败。Ubuntu 的既有配置、runtime 与凭据路径不因新增 Firefox profile 而迁移。模型 URL/key/model 配置保持不变。

CLI 单次显式 profile 优先于配置默认值。远端执行使用 Host 本机配置，client 不上传浏览器路径、任意启动参数或 profile 文件。配置可通过命令行设置并读回；help/config 查询不得启动 Firefox 或请求权限。

## 6. 动作契约

公共 actions 使用 mcc 受限 schema，内部编译为 W3C Actions，不接受任意 WebDriver 方法透传。例：

```json
{
  "version": 1,
  "steps": [
    {"type": "move", "x": 120, "y": 160, "durationMs": 200},
    {"type": "keyDown", "key": "Shift"},
    {"type": "pointerDown", "button": "left"},
    {"type": "move", "x": 220, "y": 210, "durationMs": 150},
    {"type": "move", "x": 420, "y": 320, "durationMs": 250},
    {"type": "pointerUp", "button": "left"},
    {"type": "keyUp", "key": "Shift"}
  ]
}
```

- steps 按序执行，按住状态跨 step 保持，整个请求正常结束时必须平衡释放；不提供跨 CLI 请求长期按住。
- 支持 move、pause、pointerDown/Up、keyDown/Up、scroll。键映射使用明确枚举及合法字符；Meta 在 macOS 对应 Command，Windows 与 Ubuntu 按各自标准 Meta/Super 语义处理且需单独验证；Control 在三平台都保留 Control，不自动互换。Windows、Ubuntu 常用组合以 Control 验收，不能把 macOS 的 Cmd 示例直接当作其他平台快捷键。Ubuntu 被 GNOME 保留或拦截的系统组合不承诺可用于网页，不能通过改写为其他修饰键宣称成功。
- button 支持 left/middle/right；双击编译为两次 down/up，移动只执行一次。修饰键点击编译为按键按下、点击、释放。
- 首期限制：最多 256 steps、总计划时长最多 10 秒、每段 durationMs 为 0–2000；动作文件和远端消息仍受 64KiB 上限约束。
- 拒绝非有限坐标、越界、未知字段、不平衡释放、重复按下、无效枚举。整体校验在首次输入前完成。
- scroll 保持 deltaY 正数向下、负数向上，单次范围仍为 [-1200,1200] 且非零；底层转换只做一次。
- move 的路径点/时间是请求语义；浏览器可能合并事件，不承诺 60Hz 或每个请求点都产生独立 mousemove。

## 7. 观察、坐标与 Jev

Firefox 使用网页视口截图，不混入地址栏、标签栏或整个桌面。帧记录 backend、session/context、导航代次、视口尺寸、截图尺寸和截图像素到视口 CSS 像素的转换。Firefox 连接对外坐标统一使用该帧图像像素；适配器转换后以 viewport 为 WebDriver origin。

实现应优先通过标准协议建立明确尺寸的视口并获取相同上下文的 viewport 截图。视口设置、截图比例和变更通知必须在目标 Firefox/geckodriver 组合中验证；不得用 window outer rect 代替内容视口，不得执行 JS 读取 devicePixelRatio 或硬编码标题栏高度。不能可靠获得或证明映射时返回 `COORDINATE_MAPPING_UNAVAILABLE`，该组合不进入支持列表。

缩放、视口变更、导航和目标切换使旧帧失效；协议事件不足以证明帧仍有效时拒绝坐标输入。这里是几何/上下文有效性检查，不新增 OCR 文本一致性复核，不重新引入 OCR 截断拒绝。

复用 OCR 处理与 `target.rs` 的候选协议：Jev 只接收 target 和 ID/文字候选及既有协议字段；返回 ID 后由 mcc 在该帧中解析坐标。Jev 不接收坐标或负责执行。Firefox 只读截图经统一 OCR 接口处理：macOS 复用现有识别实现，Windows 与 Ubuntu 使用各自平台适配器；候选清洗、Jev 请求构造与坐标解析只保留一套公共逻辑。

在已证明映射的截图上遵循既有图像尺寸/字节限制；过大时明确报错，不静默缩放并沿用原坐标。允许页面内容随时间变化，不能把几何有效性表述为目标语义必定不变。

## 7.1 跨平台 OCR 契约

统一接口接收已解码图像、frameId 和显式语言设置，返回 `status`、`engine`、`languages`、`items`；每项包含帧内唯一 ID、文字、图像像素坐标矩形。坐标原点统一为左上，禁止输出引擎内部缩放后的坐标。置信度仅在引擎提供时返回，不填造数值；候选 ID 不能跨帧使用。

- macOS 继续复用现有 Vision 识别。Windows 首选 `Windows.Media.Ocr`，由 Rust/WinRT 平台适配器调用，首期必须验证简体中文与英文。
- Windows 原生 OCR 是设计选型，不是已经验证的可用结论。实施首步必须在干净 Windows 11 用户环境验证 WinRT 初始化、包身份/安装方式要求、语言包、图像上限及后台交互会话中的实际调用；如需要包身份，Windows 分发采用具备相应身份的安装方式并验证 CLI/daemon/Host 均能调用，不能只在开发机通过。
- Ubuntu 选用 Jammy 仓库提供的本机 Tesseract，通过受控的短生命周期子进程识别，不新增 OCR 常驻服务。依赖为 `tesseract-ocr`、`tesseract-ocr-eng`、`tesseract-ocr-chi-sim`，首期验证 `eng`、`chi_sim` 及中英文混合文字；不要求仓库外的 Tesseract 5。实际引擎、语言数据版本及识别参数须随验收记录。
- Ubuntu 适配器将统一语言设置显式映射到 Tesseract 语言名，解析 TSV 的文字项、矩形和有效置信度；非文字层级不生成候选，置信度缺失/无效时省略该字段，不因此丢弃有效文字。引擎前处理、TSV 结构解析及坐标还原由适配器完成，候选清洗与公共归并规则继续复用，输出满足公共 OCR 契约。可执行文件与语言数据路径仅从 Host 本机受信配置解析，使用参数数组启动，不执行 shell 或接收远端任意参数；超时/取消后清理本次进程和私有临时图像。
- 缺少语言包返回 `OCR_LANGUAGE_UNAVAILABLE` 并列出所需语言；引擎不可用返回 `OCR_ENGINE_UNAVAILABLE`。禁止静默切云端、自动下载模型或忽略识别失败后继续语义点击。显式坐标动作不依赖 OCR，可继续使用。
- PaddleOCR 等作为所选本机 OCR 无法满足交付约束时的备选，需要更新本 spec 的依赖、包体及安装设计后采用；每个平台首期只采用一个 OCR 引擎，不同时打包多个引擎，也不自动降级。
- 三平台输出相同 schema，不要求识别文字/分词/置信度完全一致；测试按目标文字可定位、矩形命中和 Jev 选择结果验收。Ubuntu 中文网页/原生弹窗若不能达到定位要求，保持 OCR/Jev 未验收，不以坐标点击通过代替。
- OCR 使用 Host 上的截图与引擎，远端 client 的 OS 不决定 OCR 后端。模型只收到既有文字候选，图像与 profile 不因此上传。

## 8. 门禁、取消与状态释放

新增后端不能直接绕过当前 native InputCancellation。需抽出平台无关的门禁契约，保持既有 owner、lease、epoch、控制条和暂停原因语义；macOS 接回现有状态机，Windows 与 Ubuntu 提供同等语义的原生实现。公共契约与一致性测试共享，不要求 Windows/Ubuntu 加载 Swift，也不能复制一套“永远允许”的 Rust 状态。

- 首期仍要求目标 Firefox 窗口和页面上下文处于授权、可验证状态，沿用窗口身份、焦点、暂停和初始三秒倒计时。只读 observe 不触发接管。
- 原生 CGEvent 输入继续使用现有指针命中检查；WebDriver 输入使用目标 context 和 viewport 边界检查。协议输入不移动系统光标，不能用当前系统光标位置证明页面目标。两种检查的适用边界必须显式标记，不能声称两者相同。
- Host 软暂停仍只允许同 owner/lease 下的新请求按原规则倒计时接管。显式暂停、取消、断线不确定和崩溃恢复锁不得自动解除。
- 不提交一段无法受控中断的十秒 Actions。持续移动拆为最长 50ms 的协议片段；等待由可取消调度执行。每次提交前检查现有许可，导航/暂停后不再提交后续片段。
- 暂停不能撤销已在 Firefox 内执行的片段。50ms 是计划粒度，不是系统实时停止保证；HTTP 超时也不等于浏览器已停止。
- 中断后只进行释放动作，不补发点击或剩余轨迹。使用 WebDriver Release Actions 释放浏览器按键/按钮；释放本身可能触发 mouseup/drop 等页面效果，回执必须反映部分执行。
- 必须证明在途命令结束后释放动作才生效；请求超时导致顺序不明时进入 recovery-required，不并发盲发新的动作。必要时只终止任务拥有的浏览器会话/进程，旧连接作废。
- 无法确认释放时保持恢复锁，不返回成功，不允许自动重试原动作。断线重连通过既有回执查询判断，不按网络超时自动重放。

## 9. 回执与错误

保留现有 JSON 信封与原生回执兼容。Firefox 动作增加 backend、operationId、dispatchState（notSent/completed/partial/unknown）、completedSteps、inputState（released/held/unknown）、effectVerified:false。

completedSteps 仅计协议确认完成的完整公共 step；失败中的 step 可能已部分生效，不能用该字段断言其他输入完全未发生。正常动作结束必须是 inputState:released。sent:true 只能表示全部请求动作获协议完成确认，不能表示拖拽、登录或业务操作成功。

新增固定错误码：`FIREFOX_UNAVAILABLE`、`DRIVER_INCOMPATIBLE`、`PROFILE_IN_USE`、`BROWSER_SESSION_LOST`、`CONTEXT_CHANGED`、`COORDINATE_MAPPING_UNAVAILABLE`、`ACTION_UNSUPPORTED`、`INPUT_STATE_UNKNOWN`。现有参数、frame、暂停和远端恢复错误继续复用；日志不输出 profile 内容、Cookie、模型密钥或用户输入全文。

Ubuntu 平台检查另增加 `DESKTOP_SESSION_UNSUPPORTED`（Wayland/XWayland 或不在矩阵内的桌面会话）、`DESKTOP_SESSION_UNAVAILABLE`（未登录、锁屏或目标交互会话不可用）、`BROWSER_PACKAGE_UNSUPPORTED`（Snap/Flatpak 等未支持的 Firefox 包形态）、`WINDOW_IDENTITY_UNAVAILABLE`（无法证明原生窗口归属）。这些检查在会话创建或输入前完成，不能用继续发送 WebDriver Actions 代替桌面能力失败。

## 10. 远端兼容与资源管理

仍使用现有 WSS + token、owner/sequence 和截图传输。增加 `firefox.webdriver.v1`、`firefox.actions.v1` 能力声明；旧 Host 明确拒绝新命令，新 Host 不改变旧 Chrome/desktop 请求语义。backend 属于连接属性，不把 Firefox 伪装成 chrome scope；首期从 desktop scope 接入，兼容现有 scope 枚举。

geckodriver/Marionette/BiDi 端口只监听回环，按 owned process/session 保存实际端点。客户端不能提供任意 driver URL。明确记录 Firefox 和 geckodriver 实际版本，发布前确定并测试支持组合；不凭“最新版本”承诺兼容。

原生微信窗口通过 desktop 连接控制：macOS 复用已有实现，Windows 与 Ubuntu 通过下述原生适配器验证。在现有单连接约束下，交接前释放网页输入并断开页面控制连接；浏览器会话需由同 owner 的显式交接流程暂存，而非普通 disconnect 自动保活。交接句柄有时限，首期定为 120 秒；超时清理 owned 会话但保留 profile。恢复时重新证明 session/context/window 身份并生成新帧，不能沿用旧坐标。此交接仅用于一个暂停中的浏览器会话，不扩展成并行控制。

## 10.1 Windows 平台适配与交付边界

Firefox 协议、动作编译、Jev、回执及 WSS 逻辑共享；以下依赖不能以删除平台检查代替适配：

| 平台边界 | macOS | Windows 首期要求 |
| --- | --- | --- |
| 本地 IPC/owner | 现有私有 Unix socket 与 peer 校验 | 当前用户受限 ACL 的 Named Pipe，核验客户端身份及 owner；拒绝远程管道访问 |
| 随机 ID/私有文件 | 保留既有系统实现 | 系统安全随机源、ACL、原子写及文件锁，不依赖 `/dev/urandom` 或 POSIX mode |
| 进程管理 | 保留 owned daemon/helper 生命周期 | 管理 `mcc.exe`、`geckodriver.exe` 和 owned Firefox，使用可靠进程身份与 Job Object 等机制约束清理范围，不按进程名批量结束 |
| 窗口身份 | PID/CGWindow/AX | HWND/PID、进程创建身份及 UI Automation；防止 HWND 重用，不能凭标题认领 |
| 焦点与用户接管 | 现有激活监听和输入监测 | 前台窗口/桌面校验、用户输入监测、三秒倒计时及暂停/取消 UI；激活被系统拒绝则明确返回失败 |
| 原生弹窗 | 现有截图/OCR/CGEvent | 原生窗口截图、统一 OCR、UIA 身份/命中校验与 SendInput；禁止失败后静默切换输入机制 |
| 配置和安装 | 保留现有路径与签名流程 | 当前用户固定安装路径，配置与 profile 使用 Known Folder；路径支持空格、Unicode，升级保留数据 |

Windows Host 必须运行在已登录用户的交互桌面，不以 Session 0 服务实现 GUI 控制。锁屏、RDP 断开或会话切换导致桌面不可用时停止输入并进入恢复状态；会话恢复不重放旧请求。UAC 安全桌面、跨完整性级别输入及提权窗口不在支持范围，返回明确错误，不自动提权。

Windows 原生适配首期服务于 Firefox 门禁与微信授权交接，不承诺完整移植 macOS Chrome 启动、布局或所有桌面应用功能。权限/能力查询应报告真实平台能力，不把 macOS 屏幕录制授权提示照搬到 Windows。屏幕捕获、OCR、窗口门禁和协议输入分别报告可用性。

新增 `windows.ocr.v1` 与 `windows.native-dialog.v1` 能力仅在对应功能可用时声明；Windows Firefox 能力不能在 OCR/门禁未验收时宣称完整交付。平台专用依赖通过条件编译隔离，构建 Windows 不调用 Swift/Xcode。本地客户端与 Host 的平台组合都须经过协议验收。

## 10.2 Ubuntu 22.04 平台适配与交付边界

Ubuntu 沿用同一 Firefox 协议适配器、动作编译、Service 调度、owner/lease/epoch、Jev 与 WSS 链路，只为缺失的平台能力提供适配。既有 `private_files.rs`、`remote/credentials.rs` 的 Linux 分支继续复用；不新增绕过 daemon 的 Linux 执行器，也不把 macOS helper 改名后打包。

| 平台边界 | Ubuntu 22.04 首期要求 |
| --- | --- |
| 桌面会话 | GNOME 42 + 本地 Xorg，Host 与浏览器属于同一已登录用户的活动会话；通过 logind 会话信息和实际 X11 连接核验，不只读取 `DISPLAY`/`XDG_SESSION_TYPE` |
| 本地 IPC/owner | 复用私有 Unix socket、文件锁与现有 runtime；使用 Linux `SO_PEERCRED` 核验 UID/PID，并结合 `/proc` 进程启动身份防止 PID 重用；补齐 `daemon.rs` 的 Linux 分支 |
| 进程管理 | owned Firefox/geckodriver/OCR 进程记录 PID、启动身份和所属用户；在可用处使用 pidfd/受控进程组管理，不按名称或仅凭可能重用的 PID 清理 |
| 窗口身份 | 绑定 X11 XID、所属 X server/会话、客户端进程身份及 owned Firefox session；结合 XRes 客户端 PID、窗口层级与 `/proc` 校验，不能单凭标题或 `_NET_WM_PID` 属性认领窗口；XID 销毁/重用使连接失效 |
| 焦点与用户接管 | 使用 X11/EWMH 活动窗口、焦点和 XInput2 用户输入监测，实现三秒倒计时及可见暂停/取消 UI；激活请求被 GNOME 拒绝则停止输入，不用协议成功掩盖焦点失败 |
| 原生弹窗 | X11 窗口截图、统一 Tesseract OCR、窗口/坐标命中校验与受控 XTEST 输入；与 Firefox WebDriver 后端显式切换，不把 XTEST 用作网页 Actions 的自动降级 |
| 文件与配置 | 复用 Unix 私有文件、原子写和锁；Firefox profile 使用第 5 节的 XDG 路径；支持空格和 Unicode，升级保留既有配置及 profile |
| 构建与安装 | 在 Ubuntu 22.04 x86_64 原生构建/运行，兼容其 glibc 基线；打包 Rust CLI 与所需 Ubuntu 平台适配代码，声明本机动态库/OCR 依赖，不调用 Swift、Xcode 或 macOS 签名工具 |

Ubuntu 的 Firefox 使用显式配置的 Mozilla 官方 Linux 非容器发行包及匹配的 geckodriver，二者必须是绝对路径并记录实际版本；不用 `PATH` 中的默认 `firefox` 推断包形态。Ubuntu 22.04 默认 Snap Firefox 及 Flatpak 不进入首期矩阵，启动前检查配置目标及实际可执行文件，发现未支持包形态时返回 `BROWSER_PACKAGE_UNSUPPORTED`。不卸载或替换用户的系统 Firefox，不关闭 sandbox，不自动下载浏览器/driver。受控启动配置要求 owned Firefox 使用 X11，仍需验证实际会话/窗口，不能仅设置环境变量就判定通过。

Mozilla 已记录 Ubuntu 22.04+ 容器包与 geckodriver 可能因文件系统隔离而无法访问 profile；因此首期选用非容器包，避免混用 Snap driver、外部 driver 与个人 profile。即使单次 Snap 会话能够启动，也不能自动把它加入支持矩阵。专用 profile 必须在 owned 会话重启后保留登录态，不得以 geckodriver 的临时 profile 克隆代替持久化验收。

Ubuntu Host 只能在当前用户的交互桌面中运行；不以 root、系统级后台服务或另一个用户的 X11 授权运行。普通用户进程或绑定该图形登录会话的 user service 都必须通过相同会话检查。锁屏、注销、切换到其他用户/TTY、休眠恢复或 X server 断开时停止后续输入，按第 8 节释放并进入恢复状态；会话恢复后重新校验窗口/上下文，不重放旧请求。不能通过 `xhost +`、禁用锁屏或申请 `/dev/input`、`uinput` 的额外权限规避会话门禁。

XInput2 监测必须验证用户鼠标/键盘输入会触发既有软暂停，且适配器自己发出的 XTEST 输入不会形成自暂停循环；不能为避免自暂停而整体关闭用户接管监测。X11 原生输入需通过同一许可检查、取消和释放状态机，无法证明焦点、命中或输入释放时保持恢复锁。首期原生适配只覆盖 Firefox 门禁与已验证授权弹窗所需操作；未实现的原生动作明确返回 `ACTION_UNSUPPORTED`。

Ubuntu 权限/能力查询分别报告会话类型、X11 连接、窗口身份/焦点、用户接管与控制 UI、截图、OCR 语言及原生弹窗输入的可用性，不显示 macOS 屏幕录制授权或 Windows UAC 提示。新增 `ubuntu.x11-guard.v1`、`ubuntu.ocr.v1`、`ubuntu.native-dialog.v1` 能力，仅在对应功能可用时声明；Wayland/XWayland 会话不声明本机 Firefox 输入能力。OCR 缺包时可按第 7.1 节使用已通过门禁的显式坐标动作，但不得宣称 Ubuntu 完整交付。

Ubuntu 分发须提供依赖检查与明确的安装说明，列出 GNOME/Xorg、所需 X11 扩展/动态库、Tesseract 与 `eng`/`chi_sim` 语言包、Mozilla Firefox/geckodriver 的版本组合及来源。依赖安装由用户或分发安装步骤显式执行，help/config/status 查询不执行 apt、不申请 sudo、不下载语言模型；干净 Ubuntu 22.04 用户环境必须能按说明复现。Wayland、Snap/Flatpak、其他桌面或发行版若后续纳入，需要单独更新支持矩阵和验收证据。

微信授权交接须使用实际可安装的 Linux 微信版本验证应用身份、弹窗、OCR 与点击流程；不能假定它具备 Windows/macOS 相同的快捷登录入口。若 Linux 版本缺少目标登录入口或不能完成网页到原生弹窗的交接，明确记录 Ubuntu 业务验收阻塞，Firefox 网页测试结果单列，不能据此宣称完整业务交付。

## 11. 验收要求

| 层次 | 必须验证 |
| --- | --- |
| 纯逻辑 | CLI/schema、按钮/修饰键、输入平衡、轨迹拆分、坐标映射、配置优先级、无效参数在输入前拒绝 |
| 协议适配 | 假 driver 验证所有输入只使用 Actions；禁止脚本端点、任意 URL 转发及 JS 降级；异常释放与未知状态锁定 |
| 原生兼容 | 原有 Chrome/desktop、Jev、Host 接管与暂停回归，不改变旧命令默认行为 |
| 本地 Firefox | 事件记录页验证 hover、连续移动、左/中/右键、双击、Shift/Control/Meta 点击、普通拖动、HTML5 拖放及滚动方向 |
| 几何 | Retina、Windows 100%/125%/150%/200% DPI、Ubuntu Xorg 100%/200% 显示缩放与字体缩放、多显示器/缩放切换、页面缩放、窗口大小变化、导航、新标签页、旧帧、截图上限及错误 context；Ubuntu 未验收的分数缩放组合明确排除，不推断坐标映射 |
| 故障 | 移动中暂停、按住时取消、HTTP 超时、driver/browser 崩溃、WSS 断线、释放失败、重复 sequence 无重放 |
| 生命周期 | 专用 profile 登录态跨重启保留、profile 占用、只清理 owned 资源、交接超时回收 |
| 远端 | 三平台各自 Host+client 回环，以及 macOS/Windows/Ubuntu 每一对平台双向 client → Host，共六种跨平台组合；OCR/门禁均由 Host 决定，真实远端另行授权并确认无人使用后测试 |
| Windows OCR | 干净安装、WinRT/包身份、中文/英文语言包、缺包错误、混合文字、截图坐标与识别上限 |
| Windows 系统 | Named Pipe ACL/owner、用户切换、锁屏、RDP 断连、UAC 拒绝、窗口句柄重用、暂停/取消与 owned 进程清理 |
| Ubuntu OCR | 干净 Jammy 环境的 Tesseract/语言包、缺包错误、中文/英文及混合文字、TSV 归一化、识别上限/超时/取消、私有临时文件清理、矩形命中与 Jev 选择 |
| Ubuntu 系统 | GNOME 42/Xorg 会话核验、Wayland/XWayland 拒绝、SO_PEERCRED/owner、PID/XID 重用、焦点拒绝、锁屏/TTY/用户切换/X server 断开、可见暂停/取消、XTEST 自输入识别与 owned 资源清理 |
| Ubuntu 浏览器 | 官方非 Snap Firefox/geckodriver 版本组合、Snap/Flatpak 明确拒绝、受控 X11 启动、专用 profile 持久化与占用、不影响用户系统 Firefox |
| 三平台分发 | 各自原生构建与实机启动、配置读写、路径含空格/Unicode、profile 持久化及升级保留；Ubuntu 验证 glibc/动态库依赖及无 Swift/Xcode，交叉编译通过不能替代 Windows/Ubuntu 实机验收 |
| 业务 | Firefox 视频号快捷登录 → 有界只读等待微信窗 → 核对授权内容 → 原生点击允许 → 恢复 Firefox 并确认后台登录 |

测试页可以用自身 JS 记录 DOM 事件和展示测试结果；这是被测应用，不是 mcc 注入脚本或生成输入。验收同时检查事件与可见结果，不用 isTrusted 或单次协议 200 证明“真人操作”。

上述本地 Firefox、OCR/Jev、门禁、故障、生命周期和业务流程必须分别在 macOS、Windows 与 Ubuntu 22.04 实机验证；Windows/Linux 微信版本及可用登录入口需记录。若第三方不提供相同入口，应报告对应平台业务验收阻塞，不能用其他平台结果代替。Ubuntu 还须记录 OS 点版本、内核、GNOME/Xorg、显示缩放及 Firefox/geckodriver/Tesseract/语言数据版本。没有 Windows 或 Ubuntu 测试环境时，对应平台保持未验收状态，不将其降为后续计划。

完整交付必须记录实际版本、测试证据、未支持项和故障行为。若坐标映射、窗口绑定或取消/释放不能通过，不以“基础点击能用”标记后端完成。代码 review 由主 agent 完成。

## 12. 官方参考

- Firefox Remote Protocols：https://firefox-source-docs.mozilla.org/remote/
- geckodriver 参数：https://firefox-source-docs.mozilla.org/testing/geckodriver/Flags.html
- Firefox profiles：https://firefox-source-docs.mozilla.org/testing/geckodriver/Profiles.html
- WebDriver Actions：https://www.w3.org/TR/webdriver/#actions
- Selenium Actions 语义参考：https://www.selenium.dev/documentation/webdriver/actions_api/
- WebDriver BiDi：https://w3c.github.io/webdriver-bidi/
- Playwright Firefox 限制：https://playwright.dev/docs/browsers

- Windows OCR API：https://learn.microsoft.com/en-us/uwp/api/windows.media.ocr.ocrengine
- Windows Named Pipe 安全：https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights
- Windows SendInput 与完整性级别限制：https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput
- geckodriver 与 Ubuntu Snap/容器包限制：https://firefox-source-docs.mozilla.org/testing/geckodriver/Usage.html
- Ubuntu 22.04 Tesseract 包：https://packages.ubuntu.com/jammy/tesseract-ocr
- Ubuntu 22.04 简体中文 OCR 语言包：https://packages.ubuntu.com/jammy/tesseract-ocr-chi-sim
- Tesseract TSV 输出：https://tesseract-ocr.github.io/tessdoc/Command-Line-Usage.html
- Linux Unix socket / SO_PEERCRED：https://man7.org/linux/man-pages/man7/unix.7.html
- logind 会话接口：https://www.freedesktop.org/software/systemd/man/latest/org.freedesktop.login1.html
- X11 XRes 客户端身份协议：https://www.x.org/releases/current/doc/resourceproto/resproto.txt
- X11 EWMH 窗口约定：https://specifications.freedesktop.org/wm-spec/latest/
- XDG 基础目录规范：https://specifications.freedesktop.org/basedir-spec/latest/
