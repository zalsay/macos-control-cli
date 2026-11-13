# 2026-10-28 单一 Manager 生命周期与 AppleScript 薄入口

## 结论与边界

- 仓库 `/Volumes/RC500/dev/safarier`，分支 `mcc-safarier`，HEAD `2f32d21248deaffd8c8c1152a39912aa46350c7e`；本批次未提交、推送、安装或发布。
- 两名 terra-worker 实现，主代理执行全部 source review、独立反例、组合回归和正式产品编译。重新读取 worker 的实际 `turn_context`，两者均为 `gpt-6.1-terra` / `high`；没有 reviewer 子代理。
- 第三批完成**候选生命周期/脚本适配代码及离线验证**，不是产品后台输入功能完成。默认打包不启用 AppleScript；即使显式构造 scripting candidate，服务仍仅返回 unavailable/unverified 的 capabilities，其余全部拒绝，不连接真实 Profile 或启动受控 Runner。
- 本批次未运行真实 Safarier App、NSApplication、GUI、AppleScript 执行器或真实 Apple Events；执行的进程仅为无 GUI 验证程序和 Foundation fixture。没有使用全局鼠标键盘、DOM 注入、焦点恢复技巧、系统 TCC/工具链变更或软件安装。

## 源码复用与实现

### 单一生命周期

`/Volumes/RC500/dev/safarier/Sources/Safarier/ManagerGUI/ManagerApp.swift` 替换原 SwiftUI `ManagerApp: App` / `Scene` 启动所有者，只有一个 AppKit Manager 宿主。保留 `ManagerGUI.start() -> Never`、原 `ManagerModel` 与 `SafarierAppView`，不增加第二套管理器、浏览器或常驻服务。

- .app 元数据最早期 `LSUIElement=true`；启动代码先 accessory。模型、窗口、菜单只在显式交互效果进入 `showManager()` 时创建。裸二进制无参数仍按原习惯进入人工 GUI。
- `ascr/noop` 和脚本入口记录 automation；`aevt/oapp` / `rapp` 记录 interactive。unknown 不默认建窗，不使用 sleep/延迟猜测事件顺序；已有人工窗口收到 automation 时没有隐藏、降级或激活动作。
- 原 1080×700 默认 / 860×540 最小尺寸、9 个业务菜单命令及禁用规则、常用编辑/窗口菜单和跨 Runner 窗口循环保留。中文输入法相关键盘监听仍是 local monitor，只在人工窗口建立后安装，退出移除。
- 人工关最后一个窗口且仍有自有请求时等待排空；期间 reopen 取消窗口排空退出。显式 quit 有 pending 时先返回 terminateLater，下一主队列取消自有请求；实际脚本回复完成、registry 归零后恰好一次 reply-to-termination，不等待/自旋、不提前清空 registry。
- 纯策略、reducer 和菜单定义位于 `/Volumes/RC500/dev/safarier/Sources/SafarierCore/ManagerLaunchPolicy.swift`。AppKit 菜单只复用原 Model 动作，位于 `/Volumes/RC500/dev/safarier/Sources/Safarier/ManagerGUI/ManagerMenu.swift`。

**限制：**纯 reducer 的事件标签不证明系统实际发来的 open/reopen 一定表示人工意图。真正冷启动事件顺序、Dock/激活变化、多个同 Bundle 实例的接收者，以及迁移后 GUI/菜单实际呈现，均未执行验收。不得据这些纯测试宣布 G1 或普通 GUI 回归通过。

### 脚本薄入口与一次回复

- `/Volumes/RC500/dev/safarier/Sources/SafarierCore/AutomationScriptService.swift`：只读能力服务和脱敏 caller snapshot。要求 manager 角色、同 EUID、正 PID、正确大小的 opaque audit token；能力为 backend unavailable / uiPolicy unverified / coldLaunch unverified，其余 action 返回 BACKGROUND_LAUNCH_UNVERIFIED。
- `/Volumes/RC500/dev/safarier/Sources/SafarierCore/AutomationScriptCoordinator.swift`：复用现有严格 codec；非法身份/JSON/帧/deadline 不调用 handler。每个请求成功、异常、超时、取消只完成一次；校验返回 requestID，丢弃迟到结果；回调不在锁内执行。变更请求已进入 handler 而结果不明时 sideEffects=possible、不可自动重试；只读/未分派拒绝为 none。
- `/Volumes/RC500/dev/safarier/Sources/Safarier/Automation/AutomationRequestCommand.swift`：真实 `@objc(SFRAutomationRequestCommand): NSScriptCommand`，JSON text 输入/输出。只接受主线程 Cocoa 当前命令及 manager 角色；在 suspend 前从当前 Apple Event 复制系统只读 EUID/PID/audit 属性，检查精确类型和长度，不把请求 JSON 当身份，不解析 audit token 内部布局。EUID 使用 UInt32 bitPattern 保留高位。
- suspend 后只把 primitive snapshot 传给 Core。completion **始终排到下一主队列 turn** 才 resume，pending registry 保留命令至实际 resume 完成；退出取消与排空使用 `/Volumes/RC500/dev/safarier/Sources/Safarier/Automation/ManagerAutomationHooks.swift`，不创建或激活 NSApplication。
- `/Volumes/RC500/dev/safarier/Sources/Safarier/Resources/Safarier.sdef`：suite SFAu、command SFAurequ、automation request、text → text；Package.swift 仅增加该资源，不改最低系统、产品或测试目标。没有为了绕过默认元数据而主动加载 scripting suite；适配器不依赖 Bundle.module 的部署路径。

**限制：**synthetic descriptor 测试只证明解析和值域，不证明 OS 属性来源、真实 Apple Event 授权或系统 sender 行为。opaque token 长度不是独立认证。协调器可以有界回复、撤销 registry 并忽略迟到结果，但不能强制终止不合作的任意异步 handler；当前生产 handler 不执行变更，未来接入变更必须另有协作取消及目标进程收尾。当前 guard 只能作为后续真实 G1/授权验收的候选，不能用来放行页面控制。

### 打包元数据

`/Volumes/RC500/dev/safarier/scripts/build-app.sh` 将原 Info.plist 写入抽成同一函数，普通 sing-box/许可证/图标/架构/签名组装路径保留。

- 默认没有 NSAppleScriptEnabled=true，也没有 OSAScriptingDefinition 或主 bundle 词典。
- 只有显式 `SAFARIER_SCRIPTING_CANDIDATE=1` 才写入启用 keys 并复制词典；此开关不是通过 G1，不会把后端改为 active。
- `SAFARIER_METADATA_ONLY=1` 只对明确指定且不存在的输出目录写 Info/候选词典，拒绝已有目录和 symlink，不编译、组装二进制、签正式包或运行 App。
- 两个 flag 都严格接受 0/1，包括显式空值在内的其它值先拒绝，不能因拼写错误进入普通构建。验证使用无 `.app` 后缀的普通目录，不做 LaunchServices 注册。

## 主代理复核修正

1. caller parser 原来仅核对 audit 长度且拒绝 signed EUID 高位：补 typeAuditToken 精确类型及 UInt32(bitPattern:)，被动 RED 明确复现两个旧行为，GREEN 通过。
2. suspend/resume 必须跨原始 handler 返回边界：拒绝 inline resume，统一下一主队列；quit 改为 terminateLater + registry 归零回复，避免丢失已挂起命令。
3. 关最后一个窗口、有 pending、自然排空后原先可能留下无窗口宿主：补 reducer 排空退出及 reopen 撤销退出，RED 为 last window drained terminates 失败，修复后通过。
4. metadata-only 非法值原先可能掉入普通构建：增加前置验证，RED/GREEN 与输出 sentinel 保留检查通过。

worker RED/GREEN 证据保留在 `/Volumes/RC500/dev/safarier/.build/automation-script/proof-*` 与 `/Volumes/RC500/dev/safarier/.build/manager-launch/`。主代理读取了实际失败/成功日志，并独立重建最终代码，不只依据 worker 的完成报告。

## 本批次主代理独立验证

主代理证据目录：`/Volumes/RC500/dev/safarier/.build/automation-stage3-main-review/`。所有执行有外层时限；Core 使用**最终全部真实源码静态编译**，避免串用 worker dylib。

| 验证 | 本轮结果 |
|---|---|
| 联合共享 cases，连续 3 轮 | 每轮 protocol 340 + channel 28 + wire 117 + controlled-process 56 + script 59 + manager launch/menu 64 = 664 项，均 exit 0 |
| 独立 script coordinator，连续 3 轮 | 每轮 281 checks；64 个已进入 handler 的并发取消/重入 cancelAll/迟到返回，以及 128 次即刻取消竞争，恰好一次、无 pending 遗留、错误脱敏 |
| 独立被动 adapter，连续 3 轮 | 每轮 39 checks；UID 高位、PID、audit 类型/长度、缺字段、pending registry 50 入/出/重复 finish；不发送或执行 Apple Events |
| 独立生命周期安全遍历 | 299,592 个 reducer transition；automation 不产生窗口/退出效果、退出后不重开、termination 回复不重复；不等于 GUI 验收 |
| 独立元数据与 sdef | 32 checks；默认关闭、显式候选、原身份/floor/termination keys、词典字节相同、非法 flag/已有输出/symlink/缺目标拒绝 |
| 前两阶段独立回归 | 旧 request corpus 71、reply corpus 47、request roundtrip 28、握手/持续连接 16、真实 Foundation 子进程坏握手 5 项全部通过 |
| 正式产品 | 使用新缓存与命令级诊断 VFS overlay，实际 Package/main.swift/RunnerMain/ManagerApp/adapter/resources 编译链接 exit 0，无 warning；没有执行产物 |
| 正规 XCTest | 本轮编译探针仍 error: no such module XCTest；新 wrappers 仅语法检查，未宣称完整测试通过 |
| sdp | 当前 CLT 的 sdp shim 要求 Xcode，未转换术语资源；XML/命令结构已解析，不等于系统词典可调用验收 |

可运行的独立脚本为 `/Volumes/RC500/dev/safarier/scripts/test-manager-launch.sh` 和 `/Volumes/RC500/dev/safarier/scripts/test-automation-script.sh`；共享 cases 同时保留正规 XCTest wrappers，不用假的 XCTest 替代。

编译所用 overlay 仅把当前命令看到的 PackageDescription private interface 映射到本机已有 public interface，路径、wrapper、invocation、command/stdout/stderr/exit 均在证据目录。没有 patch 系统、全局切换 xcode-select 或安装 Xcode。它是已有 ABI 问题的诊断构建路径，不是正式可分发 release 门禁。

## 门禁及下一阶段

- **G0 未全量通过：**缺正规 XCTest，原完整测试/普通 App GUI 回归未运行；不发布、不安装、不把 debug 编译等同 release。
- **G1 未通过：**真实冷/热 AppleScript、唯一 Manager 路由、系统权限、焦点/菜单/窗口效果未验收；默认正式脚本入口保持关闭。
- **G2 未通过：**本轮没有新的实际 WebKit/后台输入验收，也没有完成 UI 逃逸、目标会话/lease、截图/收尾接入；所有真实页面操作继续 fail closed。
- 后续沿原设计实施目标授权、UI 逃逸能力快照、会话状态机与原生 driver 接口，先做可注入离线验证；不能只把 unavailable 改成 active，也不能用全局输入补失败。真实 App/输入矩阵须另在隔离图形环境按门禁执行。

最终范围检查 54/54 通过：144 个已有文件中只改变约定的 3 个代码/构建文件与 2 个设计/进度文档，另外 139 个文件保持原 hash；新增 17 个源码/测试/脚本资源文件及本报告。工具链 hash 和全局 developer directory 不变，自有 helper 遗留 0、staging 为空、diff 检查通过。仓库原有 sparse-checkout 未展开，10 个标记 skip-worktree 的文档资源不属于丢失或新删除。完整证据见上述主代理目录的 `final-review.json`。本报告不授权运行候选 App、安装/提交/发布或扩大输入白名单。
