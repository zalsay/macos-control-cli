# 2026-10-28 受控 Runner 启动与双向 RPC

## 状态

- 仓库 `/Volumes/RC500/dev/safarier`，分支 `mcc-safarier`，HEAD 仍为 `2f32d21248deaffd8c8c1152a39912aa46350c7e`，未提交/推送。
- 两名 terra-worker 实现；主代理从新 turn_context 核实均为 `gpt-6.1-terra` / `high`，主代理执行全部 review 和独立反例。无 reviewer 子代理。
- 第二批已落地受控启动和纯 Foundation RPC 链路；实际页面引擎、Manager GUI/AppleScript 入口未开放。
- 本轮运行的子进程全部是本次编译的 Foundation fixture；没有运行真实 Safarier App、浏览探针、GUI、输入模拟或原 XCTest，也没有安装/下载/修改系统工具链或 TCC。

## 已实现代码

| 文件 | 行为 |
|---|---|
| `Sources/SafarierCore/RunnerLaunchSpec.swift` | 新 backgroundAutomation 默认 false / --background-automation；与 probe 互斥；旧语言/TZ/SPI/arguments 语义保留 |
| `Sources/SafarierCore/RunnerLauncher.swift` | 保留旧 ProcessSpawning API，增加 standardInput overload；旧 conformer 默认明确不支持受控输入，绝不丢 stdin 回退。Foundation 两个入口复用同一 spawnProcess/日志/onExit 路径 |
| `Sources/SafarierCore/SafarierWorkspace.swift` | 未许可/已锁 Profile 拒绝受控启动；初始 about:blank，不自动加载 Profile.startURL；受控路径以子进程环境显式绑定 SAFARIER_HOME=workspace.root，不改全局环境 |
| `Sources/SafarierCore/AutomationChannel.swift` | 从已有 validation 抽出 validateConnectedStream；只读验证双向 connected AF_UNIX/SOCK_STREAM，原 framing/背压/关闭语义保留 |
| `Sources/SafarierCore/AutomationProtocol.swift` | encodeRequest / decodeReply，复用原重复 key/UTF-8/depth/frame 预检；强类型双向回执、字段/值域验证，不向业务层传 Any |
| `Sources/SafarierCore/AutomationHandshake.swift` | hello/ready 严格 envelope；绑定 version、role、Profile UUID、32 字节随机 nonce、Runner UUID 与实际 spawn PID；超时/取消/不匹配关闭本次连接 |
| `Sources/SafarierCore/AutomationRunnerClient.swift` | actor 化 Manager 侧连接；单在途 RPC、ID/effect/role/target Profile+Runner 校验，超时/关闭/迟到回执拒绝；不是完整 Apple Event 授权服务 |
| `Sources/SafarierCore/AutomationRunnerBootstrap.swift` | serveUnavailable 仅能力查询成功，其余 action 一律 BACKEND_UNAVAILABLE；所有返回均不执行页面行为；EOF/idle/cancel 结束自己的连接 |
| `Sources/Safarier/RunnerMain.swift` | 加背景早分支：Profile/锁和参数检查后，创建代理/NSApplication/WebView 前进入上述 Foundation 服务；普通 GUI 入口保留 |

当前 Core client 的“Manager 侧”指可被 Manager 复用的 API，不表示 ManagerGUI 已装配该 client。没有 sdef shipping 入口、冷启动生命周期变更、真实会话目标创建或本地输入 driver 调用。

## 安全不变量

- nonce 只经继承 socketpair；不放 argv、environment、日志或文件。子进程启动参数仅 Profile/语言/TZ/明确模式等原有非秘密数据。
- 通道是未命名 socketpair，无 bind/listen/端口/发现注册；正常 FileHandle/pipe/TCP 输入不能伪装成受控通道，普通模式不得携带 controlInput。
- 私有 client 绑定实际 spawn 返回的 PID，不用陈旧 PID 文件授权，不按进程名杀进程；失败关闭自己的连接，由 unavailable child 从 EOF/时限退出。
- 成功回复不仅要 ID 相同，还要与 action 的 result 类型相容；capabilities 必须 role=runner，sessionOpened/stateRead 的 Profile/Runner instance 必须与握手一致。
- 校验在发送前拒绝时 sideEffects=none。变更动作发送尝试后若超时/断连/取消/坏回执，抛出 INDETERMINATE_RESULT、retryable=false、sideEffects=possible，不补发动作。匹配的 backend failure 保留对端字段；capabilities/getState 只读失败保留原错误。
- 全部页面 action 当前都明确拒绝；不会因为 backend unavailable 自动走旧 GUI 启动、全局 CGEvent/System Events、鼠标移动、键盘或 JS fallback。
- nonce/PID/实例匹配是本次连接的一致性验证，不是代码签名认证、Apple Event caller audit 身份或完整 session/window/page 授权；那些仍需后续实现。

## 主代理 review 中修复的边界

1. 独立 45 条 reply corpus 首次仅 41 条通过：按钮 2、零 viewportWidthPoints/scaleX/pageZoom 被错误接受。Terra 补 RED/GREEN，decoder/encoder 现验证左键 mask 0/1 和有限正值；snapshot 的像素边受 4096 限制，sessionOpened 的高 DPI viewport 不被误当成截图限制。
2. invalid timeout=.infinity 曾先调用 spawner 再失败；主代理用无真实进程的 CountedSpawner 记录 calls=1。修复后 NaN/inf/非正/溢出时限在创建 FD/启动前拒绝，独立复测 calls=0。
3. 变更动作已开始发送后出现不确定结果，原 catch 曾沿用默认 sideEffects=none。Terra 增加真实收帧的 stall/drop/坏 effect/cancel fixtures 后修复；无实际点击/文本输入，只有测试数据传输。
4. busy 负例原靠固定 20ms sleep 推断已在途；现在 helper 明确收到首帧后写本次临时 ready marker，主测试在有界等待后检查 busy，再主动取消；时限负例单独测试。
5. wire 独立 CLI 增加 30 秒外层硬超时，避免取消/EOF 逻辑回归后脚本无限挂起；timeout 路径 fixture 只终止本次创建的 CLI。

原始失败未被覆盖：`.build/automation-stage2-main-review/first-independent-cases.*`、`.build/automation-wire/value-red.*`、`.build/controlled-runner/timeout-red.*`、`side-effects-red.log` 等均保留。RED 不算通过。

## 实际验证

主代理用最终全部 Core 源码编静态模块，另将 helper 也链接同一版 Core；不复用可能过期的 worker 动态模块作为最终验收。helper 只导入 Foundation/Darwin/Core，依赖检查不含 AppKit/WebKit/SwiftUI。

| 验证 | 结果 |
|---|---|
| 三轮联合验收 | 每轮 exit 0：340 protocol + 28 channel + 117 wire + 56 controlled-process checks |
| 独立 reply corpus | 47/47（含高 DPI session 放行与超限 snapshot 拒绝） |
| 独立 request encode/decode roundtrip | 28 条通过 |
| 独立 handshake/持续连接 | 16 项通过；成功 deadline 不会顺便关掉连接，可连续查询能力 |
| 真实子进程坏 ready | 5 种 nonce/Profile/PID/role/version 错误均启动失败，自己的 helper 收到 EOF 后正常退出 |
| 上批独立协议样例回归 | 71/71 + 340 核心 + 28 通道及组合检查通过 |
| 独立入口脚本 | test-automation-wire.sh exit 0 / 117 checks；test-controlled-runner.sh exit 0 / 56 checks |
| 正规 XCTest 包装与原启动相关测试 | 新增断言保留，只做语法解析；未进行 XCTest 类型检查/运行 |
| 实际 Safarier main.swift/RunnerMain Debug 编译链接 | exit 0，使用此前说明的命令级诊断 overlay；未运行产物 |

检查计数包含循环断言，不等于同数量独立 XCTest 测试。受控 fixture 覆盖 stdin 双向通道、execv 前保留 fd0、Profile/锁/未许可/旧 spawner 预拒绝、自定义 workspace 隔离、额外 FD 不继承、RPC ID/effect/role/target 错误、startup/RPC timeout、cancel/late reply 和 EOF 退出。

额外 FD 负例核对 fstat 的设备号/inode，避免把启动后重用相同编号误判为泄漏。本机 Darwin Foundation.Process 未继承未指定 FD 已有实测；不能外推所有裸 fork/exec 或第三方启动器都不存在 socketpair→CLOEXEC 的窗口。

证据主目录：`/Volumes/RC500/dev/safarier/.build/automation-stage2-main-review/`，含 final-source-hashes、各命令/退出码、combined-round-1/2/3、independent-final、independent-handshake、real-handshake-negative、legacy-71-cases、final-product-build 等。worker RED/GREEN 分别在 `.build/automation-wire/`、`.build/controlled-runner/`。

## 尚未完成／不能据此放行

- 真实 App 冷启动无激活、唯一 Manager Apple Event 接收者、ManagerGUI 生命周期与 AppleScript sdef/命令均未实现/验收。不能把 Foundation helper 无 GUI 等同于真实 App 首次启动不抢焦点。
- 当前背景服务有意在代理/WebKit 初始化之前拒绝操作；未来真实原生后端接入必须恢复原 Profile 代理/语言时区/数据存储流程，并在正确 checkpoint 采用 stdin，不能仅将 unavailable 改 active。
- client 还不是完整 caller/session/window/page 权限控制器；本批次仅绑定 Profile/Runner，实际目标窗口/页面与授权 lease 仍待会话层落实。
- deadline 覆盖握手/RPC 的异步 I/O；同步 Foundation Process.run 本身不是可抢占操作，不承诺任意系统阻塞下严格整个启动都在给定秒数内返回。
- 未做实际 WebView hover/down/drag/up、系统 UI 逃逸、权限弹窗、输入法、多屏或用户日常桌面验收；原 XCTest 仍缺环境，release/签名/App 打包未执行。
- 未安装/发布/提交/推送，不改变全局 Developer 选择或系统 SDK。阶段1原生桥及其它未授权文件保持原样。
