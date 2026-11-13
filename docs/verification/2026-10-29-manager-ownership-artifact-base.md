# 第九批：Manager 会话归属、撤权通知与可信 artifacts base

日期：2026-10-29（Asia/Shanghai）

## 状态与范围

**本批候选代码及以下无 GUI 验证已完成；完整页面自动化仍未开放。** Manager 现在有会话归属/请求路由代码，Command/GUI 生命周期和持久权限通知已接入；固定 artifacts 基目录可由原 SnapshotStore 安全准备。实际 Runner 的后台 Profile/代理/配置准备及 G0/G1/G2 仍未完成，不能据此启用键鼠控制。

仓库 `/Volumes/RC500/dev/safarier`，分支 `mcc-safarier`，HEAD `2f32d21248deaffd8c8c1152a39912aa46350c7e`。前八批 dirty work 保留；基线 224 文件，215 个原文件不变，9 个限定路径修改，新增 16 文件（含本报告）。最终 215 个 Source/Test/scripts 文件按 SHA-256 冻结。无提交、推送、安装或发布。

生产实现由三个实际上下文为 gpt-6.1-terra/high 的 worker 执行；设计、代码审查、独立测试和集成验收均由主代理完成，没有 reviewer 子代理。

## 实现

### Manager 与 caller / endpoint 归属

- `/Volumes/RC500/dev/safarier/Sources/Safarier/Automation/AutomationManager.swift`：Foundation-only registry，复用原 AutomationRunnerClient、ReplayCache、strict codec；不重写原生按钮状态机。每个 Profile 一个自有 endpoint，活动与未返回创建/清理额度有界；打开记录、重放和终态元数据也有上限。
- `/Volumes/RC500/dev/safarier/Sources/Safarier/Automation/AutomationManagerEndpoint.swift`：薄 endpoint 契约，原 RunnerClient 直接遵循，没有修改其 transport/tombstone 行为。
- `/Volumes/RC500/dev/safarier/Sources/SafarierCore/AutomationScriptService.swift`：CallerProof 仅新增私有 audit bytes 比较方法；原 shipping handle 硬拒绝不变。session 绑定 UID、PID、opaque audit token、完整 target 与 endpoint PID/instance/ownershipID；错误 caller/token 不读 Profile、不转发、不清理别人的对象。
- 重放不再次向 Client 发送物理动作。初始 open ID 不能当作输入/关闭 ID 使用；过期/关闭不复活 token。权限在初始打开和每个动作（含缓存回执返回前）重读。
- cancel/close/撤权/quit 只关自己的通道，有界观察实际 owned Process；不按 PID 文件/进程名认领，不发信号。cleaned 保守 false，只有匹配的实际退出观察才使 terminatedOwnedRunner=true。并发 close 共享同一终态，迟到退出不改写已返回的未知。
- 初始 open 30 秒、普通动作 5 秒、导航 30 秒、清理 2 秒均用实际 monotonic deadline；晚到 factory/结果不发布 token，晚到自身 endpoint 仍尝试一次安全清理。timer 失败或提前返回 fail closed，不忙循环。

**shipping admission 同时保留独立 cold-launch=false 与 NativeInputPreflight=false。** 不是日后只翻开 Native gate 就能绕过 G1；当前非 capabilities 请求在任何 Profile I/O、目录准备和 spawn 前继续 BACKGROUND_LAUNCH_UNVERIFIED。

### Command、Model 与退出生命周期

- `/Volumes/RC500/dev/safarier/Sources/Safarier/Automation/AutomationRequestCommand.swift`、`ManagerAutomationHooks.swift`：原同步 OS proof 拷贝、当前 command/role 检查、下一主队列恢复和一次 pending registry 保留；handler 经 hooks 到唯一 shipping Manager，无 delegate 则回原拒绝服务。
- `/Volumes/RC500/dev/safarier/Sources/Safarier/ManagerGUI/ManagerApp.swift`：delegate 持有 metadata-only Manager。Script pending 与 opening/active/closing ownership 工作合计决定退出；先返回 terminateLater，再异步取消和清理，终态历史不阻塞退出。human window/menu/activate/local-keyboard 原路径未增加自动隐藏或恢复焦点操作。
- `/Volumes/RC500/dev/safarier/Sources/Safarier/ManagerGUI/ManagerModel.swift`：保存成功后、完整 reload 前读回持久权限；reload 先发送完整 allowed UUID 集合，再读代理/订阅。Profile 读取失败发送空集合；其他文件错误不掩盖已经读到的撤权。失败 save 不发送成功通知。仅关闭 Manager registry 自己的 session。
- `/Volumes/RC500/dev/safarier/Sources/SafarierCore/AutomationScriptCoordinator.swift`：总容量 256，普通准入阈值 254，为 cancel/close 保留两个槽；取消但尚未返回的 handler 继续占额。Command 在 suspend 前独立检查，Coordinator 对直接调用也独立检查。截止时间从收到请求时建立，发送前及完成时复核；没有全局输入、队列重试或第二套 replay。

### 固定私有截图基目录

`/Volumes/RC500/dev/safarier/Sources/SafarierCore/AutomationSnapshotStore.swift` 新增：

```swift
AutomationSnapshotStore(workspaceRoot: URL, clock: @Sendable () -> Double = ...)
```

- 只准备固定 `workspaceRoot/automation-artifacts`，复用原 descriptor/no-follow/identity 路径链；没有 wire 输出路径或第二个 path walker。
- workspace 必须是本 UID、无 group/world 写入和危险 mode bits；ACL 仅允许可证明不授予写入的 read-only ALLOW / DENY。写入、删除、安全/所有权变更及未知 ALLOW bits 拒绝。
- 新 base 才设置 0700、清继承 ACL 并 readback；已有 base 只验证 UID/0700/no ACL/identity，错误 mode/ACL/file/symlink 原样拒绝，不能擅自 chmod、清 ACL 或删除。
- 固定 base 留存，原每 session UUID 子目录、0600 文件、quota/TTL/登记清理不变，不扫描其他 session 或未知文件。无法对敌对同 UID 并发路径替换作绝对原子免疫保证；失败新建过程可能保留空的自身目录，不递归补删。
- `/Volumes/RC500/dev/safarier/Sources/Safarier/Browser/BrowserSession.swift` 的 factory 仅换为该构造；文件 I/O 仍由 service 的 detached 工作执行。旧 baseDirectory 构造兼容不变。

## 主代理复核发现与修正

本批不是只接受 worker 自报 GREEN。主代理追踪并交回修复：

1. Manager 转发错误不能只复制 error.code，否则会把不确定的变更从 sideEffects=possible 变成 none；必须保留完整错误。
2. 打开/动作/清理不能 await 一个不配合取消的依赖到永久；有效取消、超时、撤权先使 owner 失效，晚到 factory 自身清理而不返回 token。
3. scheduler throw/提前返回不能被吞掉或 1ms 重试；清理即便已未知，也要尝试一次自己的安全关通道，不用迟到成功覆盖 false。
4. 重放窗口满/过期不能挡住已认证 cancel/close；startup 时间不能先耗尽 session cache，绑定成功才初始化会话 cache。
5. 前端/Coordinator 两层都必须预留控制容量，不能只在 Manager/Client 留槽；已取消而未返回的 worker 不能释放额度后无限积累。
6. 初始旧 worker 的 API/RED scaffolding不算实现完成；Manager 全功能候选、边界补丁和合流快照均重新验证。

主代理的初版文件 fixture 受 umask 影响，请求 0702 实际创建 0700，造成“接受 writable root”的假失败。已记录实际 mode，并只 chmod 自己的 fixture 到目标 mode 后重跑；没有修改生产判断或用户目录。日志为 `harness-umask-fixture.*`、`umask-verification.json`。

部分主代理初次 Manager 测试取到的已经是 worker 修正后的版本，直接 GREEN；不会把这些误写成独立 RED。worker 自身的类型/行为 RED 另存于相应目录。

## 最终验证

主代理原始 argv/stdout/stderr/exit、冻结 hash、routing 与审计：

`/Volumes/RC500/dev/safarier/.build/automation-stage9-main-review/`

### 冻结源码，连续三轮，每轮联合 2,228 项

| 模块 | 每轮检查数 |
|---|---:|
| Protocol / Channel / Wire | 340 / 28 / 117 |
| Controlled Runner / Script / Manager launch | 56 / 59 / 64 |
| Policy / Session / UI boundary | 117 / 354 / 395 |
| Controller / Native preflight / Snapshot | 319 / 60 / 69 |
| Multiplex / Owned Process / Runner service | 35 / 104 / 51 |
| Workspace artifact base / Manager | 39 / 21 |

### 主代理独立验证，以下各三轮

- Manager 11：caller/audit 不匹配、wrong token 优先级、重放一次、撤权不被缓存绕过、变更不确定性、关闭不复活、取消后不发布成功。endpoint 是明确的 synthetic fixture。
- artifact base 29：真实私有 POSIX/ACL、多 session 分离、根/已有对象不被修改、symlink/file/模式/多 ACE 写入拒绝、非法时钟/URL 在文件副作用前拒绝。
- scheduler 4：throw/提前返回 fail closed，不启动 factory。
- **实际 Manager → 原 Client → Foundation 子进程 → 原 server IPC 8**：真实 nonce/instance/锁/Process，重放不二次发送、错 caller 不关子进程、EOF 后观察真实退出和释放锁。子进程只写 fixture 标记，不包含 AppKit/WebKit 或真实输入。
- intake 容量：254 个普通未返回 worker + 2 控制槽，第三个控制拒绝；释放后恢复，64 并发、128 立即取消。
- 前八批独立 controller/boundary/session/policy/script/native-preflight/snapshot/caller、服务/打开/ID/完成取消/导航关联、受控 client/server/owned process 全部重复通过；包含每轮 100 次完成取消反例、9,000 次关联检查。全部不运行真实输入。

### 普通产品与 metadata / Model 实际代码

- 最终普通产品和诊断 probe 编译链接均 exit 0、无 warning。probe 只编译，未执行；正常产品诊断 ctor/trace 符号 0，诊断二进制对应 5。
- 沿用单命令 ManifestAPI VFS overlay，不改选中开发目录和 5 个受保护系统工具链文件。
- 链接本次普通产品对象的小 CLI 三轮通过：Factory 8 次 early denial（credential/privacy=0）、Native admission 拒绝、Runner Entry unavailable 且 NSApplication=nil。
- 新增**实际 ManagerModel/Hook/Delegate/shipping 12 项**三轮：仅访问自有 fixtures，验证初始完整权限快照、成功 save/损坏代理/Profile 读取失败通知、失败 save 无通知、合计退出工作计数、原服务 fallback、shipping 拒绝前不创建元数据目录；NSApplication 始终 nil，不启动 GUI，不发送 Apple Event。
- metadata/sdef 32 项通过，默认脚本启用状态不变；wrapper 仅 Swift syntax parse、shell/source 检查通过。
- 四个截止边界用例在私有源码副本中仅插入调度延迟，验证过期不开始/不返回迟到成功/一次取消/定时器晚开始不重新计完整间隔；这些不是原生/GUI 验收，production 没有测试 env flag。
- 实际 import XCTest 仍为 `no such module 'XCTest'`，没有执行正规 XCTest/AppTests。测试和工具链限制没有被改写成“全部测试通过”。

复核入口：

```sh
cd /Volumes/RC500/dev/safarier
python3 /Volumes/RC500/dev/safarier/.build/automation-stage9-main-review/Validate.py
python3 /Volumes/RC500/dev/safarier/.build/automation-stage9-main-review/ProductQA.py
python3 /Volumes/RC500/dev/safarier/.build/automation-stage9-main-review/SymbolReview.py
python3 /Volumes/RC500/dev/safarier/.build/automation-stage9-main-review/FinalReview.py
```

## 未完成及不可宣称的事项

- Manager/Command 的候选路由已接入，但独立 cold gate 仍 false；Runner Entry 仍 unavailable。实际后台 Profile/代理/sing-box/语言时区/数据存储配置准备未连到页面创建，因此不是完整 AppleScript 页面控制已可用。
- UID/PID/audit token 的测试是 synthetic，不等于实际 OS sender 来源或冷启动不抢焦点已验收。Model/Hook 测试不等于实际 GUI 退出/通知时序验收。
- 历史缓存重播不无限延长远端 lease；held/按钮/原生状态由原 Runner machine 负责，不由 Manager 猜测。
- native activity、hover/held/drag、WebView 完整销毁、零 click/drop 和用户同时使用其他 App 的物理非干扰验收未运行。G0/G1/G2 和 53 项真实 UI 能力不放行。
- 本轮无真实 App/GUI/probe/native/cursor/键鼠/Apple Events，无真实 Profile 数据访问，无系统权限/工具链变更。没有全局输入、System Events、DOM/JS 输入或“抢焦点再还原”兜底；无进程信号或其他会话 PID 清理。
