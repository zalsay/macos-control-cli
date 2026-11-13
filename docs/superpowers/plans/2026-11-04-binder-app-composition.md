# Binder App 组合实施计划（候选）

**状态：PROPOSED；全部 implementation pending，主 agent 审阅及用户确认均未完成。**
配套设计：`docs/superpowers/specs/2026-11-04-binder-app-composition-design.md`。
本轮只写文档，不运行代码、测试、GUI、打包或提交；不自动 commit。
每包命令类别仅为未来选项，须取得相应授权后执行；精确命令和输出范围执行前记录。

## 总览与依赖

- 工程阶段一：P0 定界 → P1 无 GUI Core 模块化和原锁借用；**不依赖新产品信任根**。
- 工程阶段二：P2 信任适配 → P3 现有 App 接线 → P4 定向集成构建／单独打包门禁。
- P5 最小 GUI smoke、P6 输入及非干扰另行授权；各阶段证据不互相代替。
- 当前 `shipping`、`liveAdapter`、`GUIExecutionAuthorized`、`input` 等合同政策门禁均为 false。
- 主 agent 独立完成 code/design/doc review；本计划不委派审查。

## 现有调用链和固定范围

ManagerAppDelegate 使用 `AutomationManager.shipping`，现有 runnerFactory 调用 `AutomationRunnerClient.start`。
Manager admission 的 `NativeInputPreflight.shippingAdmissionAvailable` 和 `coldLaunchVerified` 当前均为 false；原 caller proof 保留。
RunnerMain 保留原 ProfileLock；`BackgroundStartupControlWatch` 只 dup/poll，不消费排队 hello。
现有不可达正向分支先 prepare，`service.serve` 自建 server 后才握手；不得新建第二 server 或 reader。
`RunnerMain.makeAutomationService` 当前显式调用 `NSApplication.shared`、新建 service UUID；改用同一已认证 server instance。
service `handle` 是业务入口；`repositoryPermission` 是业务撤权 Bool，不是原 provider/kernel identity。
不因 Binder 增加新 Manager、coordinator、helper、第二 executor 或外部协议。

## P0：一次性实施边界确认 [pending]

目标：主 agent 与用户确认下列 Core 首包边界，而非每个内部函数重复确认。
- [ ] 读取原 `Package.swift`、Core 原锁/通道、attempt-016 源与 main-callgraph，列实际依赖及 Swift 可见性。
- [ ] 选定 Core 私有 C targets 的 include 布局；首包两个原 C 文件与 header 字节不变，记录逐文件 SHA。
- [ ] 确认原锁 mutex、opaque lease、同步撤销、drain 后释放的状态机及无法确认清理的处理。
- [ ] 核对 `JSONDocumentStore.save` 的默认目录属性与 atomic 写：真实 root/locks 0700、profiles.json 0600 不受保证，不从 fixture 推断；禁止擅自 chmod 或迁移用户资料。
- [ ] 确认仅可运行的无 GUI 定向测试与安全文件范围；禁止将完整 `swift test` 当无 GUI 预检。
- [ ] 取得用户对阶段一实现和相应无 GUI 验证的一次授权；不自动扩大到 App、打包或 GUI。

目标文件：本计划与配套设计；执行证据仅限另行指定的新 stage。命令类别：只读源与 hash。
退出：范围与可用验证经确认；产品信任根可以尚未解决。

## P1：无 GUI Core 模块化与原锁生命周期 [pending；依赖 P0]

目标文件：`Package.swift`；新增 `Sources/BinderIdentity/{BinderIdentity.c,include/BinderIdentity.h}`、
`Sources/BundleInventory/{BundleInventory.c,include/BundleInventory.h}`；`Sources/SafarierCore/ProfileLock.swift`；
按实际依赖最小新增 Core bridge 文件及 `Tests/SafarierCoreTests/` 聚焦用例，不搬完整 30 文件。
- [ ] 先写锁借用、并发 release、撤销、in-flight 与最后 lease、无借用普通 release 回归；不引入 GUI。
- [ ] 记录首次缺 API 的编译失败为**结构性证据**；仅在可编译原路径或获准隔离副本上观测到目标行为违反才称 runtime RED。
- [ ] 将两个 C `.c` 与对应 header 原字节放入 target 布局，核对 SHA；若必须修改 C 算法，停止并另列必要性和证据。
- [ ] 在原 `ProfileLock` 内加 mutex 与不透明 lease：release 同步撤销、禁止新检查，实际 close 在跟踪操作及资源 drain、最后 lease 后。
- [ ] 验证无跨 await 持 mutex、无 MainActor 自等待、无 fd 输出/reacquire、无 `@unchecked Sendable` 代替同步；不触正向 App。
- [ ] 定向执行获准 Core normal/ASan 和 API 负例；验证 `cleanup_unconfirmed` 不伪称安全释放及原 owner/fresh birth 边界。

命令类别：逐文件 hash、定向无 GUI Core 测试/离线 harness、定向 ASan；先确认测试不启动 App/GUI。
退出：列完整命令、RED/编译缺失区别、正常与 ASan 结果、文件 hash 和未覆盖项；main 独立审阅。
若无法获得合法 runtime RED，记录未获得，不能用 fake 授权或跳过现有验证制造 RED。

## P2：正向信任适配 [pending；依赖 P1，另须用户确认]

目标文件：拟新增 Core `KernelIdentityBridge.swift`、`PrivateDirectoryPin.swift`、`BundleResourcePin.swift`、
`RepositoryBindingProvider.swift`、`FrameDeadline.swift`、`RunnerBinderContext.swift`；实际按 P0 依赖减量。
- [ ] 比较 `OfflineBundleContract.fixture/candidate` 与真实构建布局；拒绝旧 `sh.safarier.g1probe`、旧哈希及 `makeFixture` 作为新产品授权。
- [ ] 先确认静态 namespace、资源与 helper 的非自引用 pin；禁止把最终主程序/`CodeResources` SHA 嵌入同一 exe。
- [ ] 分别确定本地已审构建的有界诊断信任、OS static/dynamic code identity 要求和分发 signer/update 策略；不预设购买 Developer ID 或安装工具。
- [ ] 批准独立信任根之前保持 positive adapter unavailable；真实 workspace 和 bundle 源、资源缺失及变更均默认拒绝。
- [ ] 将 `SAFARIER_HOME` 仅作现有定位输入，通过原 workspace/owned launch pin 同一路径；不可把环境字符串当授权或由 Bundle 父目录推导 workspace。
- [ ] 保留严格 pin/owner/no-follow/hardlink/完整文档观测；未知布局或 mode 默认拒绝，atomic 写的 inode 替换或文档变化使原 baseline 失效，禁止自动 rebaseline。

命令类别：只读 bundle/build 源审查、无 GUI 定向 normal/ASan；禁止以字符串、路径、开关或测试对象授权。
退出：独立信任方案、存储布局/mode 兼容边界及发布/更新策略经确认且有定向证据；缺失则 unavailable，不影响已完成 P1。不扩展为存储改造。

## P3：单 server / 原 App 接线 [pending；依赖 P2，另须用户确认]

目标文件：Core `AutomationChannel.swift`、`AutomationHandshake.swift`、`AutomationRunnerClient.swift`、
`AutomationRunnerServer.swift`、`OwnedRunnerProcess.swift`；App `RunnerMain.swift`、`RunnerPreparation.swift`、
`Browser/BrowserSession.swift`、`Automation/{RunnerAutomationService,RunnerAutomationController,OwnedBrowserAutomationPage}.swift`；必要时现有 `NativePageInput.swift`。
- [ ] 先写同一 server/lease、hello 唯一读取、EOF/延迟准备、同一 context 与 instance、旧回调和 cleanup 次序的聚焦用例。
- [ ] 用原 server 移植 `beginV1Handshake → sendV1Ready → serveV1Handoff`；ready 只代表 transport，在原 phase deadline/取消监视下准备。
- [ ] 拟建 App `@MainActor BoundRunnerServiceSlot`：unbound→bind-once→closing/revoked→closed，只转发已有 `service.handle`。
- [ ] 将 server 的 `runnerInstanceID`、同一 context 贯穿 `RunnerMain.makeAutomationService` 到 service/page；禁止再调自建 server 的 `service.serve`。
- [ ] 保留 `repositoryPermission`、caller proof 和 Manager gate；禁止 test-only 正向对象绕过硬拒绝或提前调用 `NSApplication.shared`。
- [ ] 定向验证超时不续期、不扩帧上限/45 秒、不增 wire 字段；无法满足需求则停并另审协议，不双读。

命令类别：确认不启动 GUI 的定向 Core/App 逻辑测试及隔离 normal/ASan；无 GUI 条件无法提供行为 RED 时明示。
退出：身份成功才准备、EOF 零 GUI、原锁最后释放、人工启动不变及同代回调证据；main 独立审阅。
Core 接入不等于 Manager/AppleScript 或输入门禁开放。

## P4：定向 build 与单独 package 门禁 [pending；依赖 P3]

目标：指定当前源码的完整 App build；package 非本计划自动步骤。
- [ ] 单独获得 build 授权，记录目标、工具、输出范围，执行获准的定向 build；不启动 App。
- [ ] 报告 no-GUI 测试与 build 的独立结果；不把历史 208 CLI 或编译成功写成 GUI 验收。
- [ ] 若申请 package，先只读审查 `scripts/build-app.sh` 全部输出、build、helper、签名及删除行为。
- [ ] 确认第 130 行 `rm -rf "$APP"`、第 153 行 icon 临时目录删除；核实 canonical 新 `SAFARIER_APP_OUT`，不触旧 dist/已安装 App。
- [ ] 输出、临时删除等副作用分别得到明确授权后才考虑沿原脚本执行；做不到则停，不静默改道。

命令类别：经授权的 build；package 须单独授权。退出：分别记录 build/package、产物 hash 与未验证风险。

## P5：最小 GUI smoke [pending；依赖 P4 和单独授权]

目标：最小受控候选、一次获准的空白或本地 fixture，无输入。
- [ ] 事先确认候选、独立身份策略、隔离 workspace、清理边界和每项 GUI 行为的授权；可另行授权新建符合约束的可丢弃 workspace，不迁移真实用户资料。
- [ ] 首次 GUI 不循环要求 G1/G2/G4/G5 均已通过；按适用性在 GUI 阶段独立收集证据。
- [ ] 仅空白或本地 fixture，观察启动、断连和自有资源清理；不进行键鼠、全局输入或外网导航。
- [ ] 遇身份不符、意外权限提示、超范围行为立即停止；不接受权限提示，不宣称完整 AppleScript 验收。

命令类别：仅经授权的 GUI smoke；退出：逐项记录可观察事实、门禁与缺口，不标记全面 GUI ready。

## P6：输入与非干扰 [pending；依赖 P5 和再次授权]

- [ ] 用户另行批准 owned-page 输入、前台非干扰、各 gate 及清理范围。
- [ ] 只使用现有 owned-view 输入路径；不引入全局输入 fallback。
- [ ] 按适用性单独报告 G1/G2/G4/G5、caller proof、AppleScript、输入与清理；失败即停。

命令类别：仅明示获准的 GUI/input 验证；退出：结果与未完成项逐项独立记录。

## 最终验收清单

- [ ] 身份成功才准备；EOF 期间零 GUI 构造；same server/lease/context/instance，旧 callback 不生效。
- [ ] 原 page/preparation 等资源 drain 后才释放原锁；`cleanup_unconfirmed` 不伪称成功。
- [ ] 普通人工启动不变；v1 与 8+2、2+2、262160、4096 不变；testhooks 不入产品。
- [ ] compile 缺 API 与真实 runtime RED 分别记录；无自动提交，无未授权 GUI/打包。
- [ ] 不要求 VM、默认满量 4096 或穷尽 EINTR；不泛泛增加等价 CLI 轮次。
