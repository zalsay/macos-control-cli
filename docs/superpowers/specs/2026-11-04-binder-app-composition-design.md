# Binder 与 App 组合设计（候选）

**状态：PROPOSED；主 agent 审阅与用户确认均未完成。**本轮仅撰写设计，不接入、不构建、不运行 App。
本设计分两阶段：①无 GUI Core 模块化和原锁生命周期；②信任适配及原 App 接线。
最小 GUI smoke、后续输入／非干扰验收分别另行授权，不是本设计的隐含许可。
所有政策门禁保持 false；这些是政策状态，并非对系统权限数据库的判断。

## 现有事实

1. Manager：`ManagerAppDelegate.init` 使用 `AutomationManager.shipping`；其现有 `runnerFactory` 调用 `AutomationRunnerClient.start`。
2. Manager admission 受 `NativeInputPreflight.shippingAdmissionAvailable` 和 `coldLaunchVerified` 约束，当前均为 false；原 caller proof 仍须验证。
3. Core：client 经 `SafarierWorkspace.launchOwnedBackground`、`RunnerLauncher` 创建原 `OwnedRunnerProcess`，现有启动握手后启动 client reader。
4. Runner：`RunnerMain.start` 解析 spec、读取 workspace/profile，将新取得的 `ProfileLock` 保存在静态 `lock`，再进入后台入口。
5. 当前后台入口先走 `serveUnavailable` 硬拒绝；不可达正向分支依次 watch、`prepareBackground`、`makeAutomationService`、`service.serve` 才握手。
6. `BackgroundStartupControlWatch` 仅 dup + poll；源码注明队列中的 hello 不读、不消费。缺口是准备先于握手，不是已有双帧读取 bug。
7. `RunnerAutomationService.serve` 自建 server；`handle` 是现有业务入口，`repositoryPermission` 是重读 workspace 的业务 Bool，均不是身份验证。
8. `RunnerMain.makeAutomationService` 显式首次调用此后台路径的 `NSApplication.shared`、构造 `BrowserSession`，并给 service 新建 UUID。
9. `ProfileLock` 当前 `release()` 为 public、descriptor 私有、无并发同步且非 Sendable；`Package.swift` 当前没有两个 Binder C target。
10. attempt-016 的 30 源文件是离线暂存；历史 main-final-audit 的 104 normal + 104 ASan 不等于产品接入、App 或 GUI 验收。

上述未接通分支的排序及 UUID 是接入义务，不声称当前 shipping 已发生不安全行为。

## 路线比较

- A：在原 Core client/channel/server 和原 App Runner 路径接入同一 context；推荐，不新增 helper、第二 executor 或 Manager/coordinator。
- B：另建 helper/broker 做身份与通道管理；引入额外信任与生命周期，不推荐。
- C：照搬 30 个离线文件或保留并行 fixture runtime；重复协议与路径且混入假设，不推荐。

## 模块与迁移映射

| 已有来源 | 拟议目标及边界 |
|---|---|
| attempt-016 `BinderIdentity.c/.h`、`BundleInventory.c/.h` | `Sources/BinderIdentity/`、`Sources/BundleInventory/` 两个 SwiftPM 私有 C target；首包保持两个 C 文件及 header **字节不变**，只适配 target/include 布局。任何 C 算法删改或裁剪须另列必要性与证据，不能顺手清理。 |
| `Package.swift` | Core 依赖上述 target；不新增 library product，不把 AppKit/WebKit 放进 Core。 |
| `KernelIdentityBridge`、`PrivateDirectoryPin`、`BundleResourcePin`、`RepositoryBindingProvider`、`FrameDeadline` | 提取必要 Swift 机制进同名 Core 文件；保留实际验证和原 baseline，不整包复制 30 文件。fixture 工厂、测试 hooks 不入产品。 |
| `AutomationChannel`、`AutomationHandshake`、`AutomationRunnerClient`、`AutomationRunnerServer`、`OwnedRunnerProcess` | 在现有 Core 同名文件迁移对应单 reader、绑定写入、deadline、generation 及 owner 逻辑；不新增并行 client/writer。 |
| `ProfileLock.swift` | 在原类内部实现封闭借用、观察和撤销；不公开 fd，也不按路径重新 acquire。 |
| `RunnerMain.swift`、`RunnerPreparation.swift` | 在现有入口持有原锁、创建/传递 Core context，连接同一 server 和 lease；保持普通人工启动路径。 |
| `Browser/BrowserSession.swift`、`Automation/RunnerAutomationService.swift`、`RunnerAutomationController.swift`、`OwnedBrowserAutomationPage.swift` | 同一 context、server instance ID 沿真实构造链传递，既有权限及 target 回调保留为业务检查。 |
| `NativePageInput.swift` | 沿用原 owned-view 输入路径和独立许可；不得增加全局输入 fallback。 |

## 原锁：推荐借用与释放契约

以下均为拟议、尚未实现；需用户一次确认实施包，不逐个内部方法重新申请。
- `ProfileLock` 内部 mutex 保护状态、借用计数、在途同步观察和撤销登记；返回仅 Core 可构造的不透明 lease。
- lease 关联同一个原锁对象和同一个 context；检查在锁内部观察持有对象和内核/文件身份，永不把 fd 交给 App。
- `release()` 有借用时同步标记撤销、禁止新检查并触发同一 context 撤销；不可在 mutex 内跨 await 或执行可重入回调。
- 实际 unlock/close 必须等已跟踪操作及自有 page/preparation drain 完成、最后 lease 结束；不能阻塞 MainActor 等待自己完成。
- 无借用的普通人工 release 保持原行为；并发 release、重复撤销及 lease 结束均须幂等。
- 非 Sendable 原类不能靠 `@unchecked Sendable` 替代真实同步；不读取 PID 文件授权、不重新 acquire 锁路径。
- cleanup 无法确认时报告 `cleanup_unconfirmed`，不靠任意 Bool receipt 声称锁已安全释放。
- 必要时仅经保留的原真实 owner、fresh birth 比对后请求退出；不得 PID 扫描或基于 wire PID 杀进程。

## 拟新增 Core API 与职责（不是现有 API）

| 拟议接口／类型 | 职责及不可变约束 |
|---|---|
| `ProfileLock` 内部 `borrowForBinder(...) throws -> HeldLockLease` | 在原对象内申请不透明借用、注册 context 撤销；不输出 descriptor；租约结束由 Core 跟踪。 |
| `HeldLockLease` 内部 `observe(...) throws` / `finish()` | 检查锁与已 pin 对象、遵守撤销和在途计数；完成后不可复用。具体同步实现需证明无死锁。 |
| `public final class RunnerBinderContext` | Core 创建的 opaque 引用；App 只能保留和传递，无 public init、无任意 provider 注入或基线重建。 |
| Core 工厂 `makeRunnerContext(workspace:spec:heldLock:...) throws -> RunnerBinderContext` | 拟议的正向工厂；从可信的真实来源建立一次 baseline、绑定原锁和 kernel identity；信任根未确认前不可开放正向能力。 |
| context 内部 `check(phase:deadline:)` / `revoke()` | 使用同一 provider、原锁借用、peer/birth 和 baseline；每次关键 await 后、提交或写入边界重查；撤销幂等。 |
| server 的 `beginV1Handshake`、`sendV1Ready`、`serveV1Handoff` | 拟从离线 seam 移植到 Core；同 server 的一次性 token/lease，不是当前产品已提供的 API。 |

公开 facade 的具体参数类型以满足 Swift 模块可见性为准，但不得公开 C handle、fd、可构造身份或身份授权闭包。
Core 保留原完整 provider 和观察；不得 await 后 fresh make provider 或以新 baseline 接受改变。

## 单 server、单 reader 与业务绑定

推荐严格沿离线 seam：**身份绑定 + hello → ready → prepare/bind → request loop**。
ready 只代表 transport 握手，不承诺业务或 GUI 已就绪；原固定 phase deadline 与取消监视贯穿，不能重新计时。
保持离线 seam 的 45 秒 outer lifetime 和帧期限上限，不延长、不增加 wire 字段；准备慢则在原截止失败。
若正式需求不能满足该时序，停止并另审协议，不能双读或暗中提高上限。

1. 创建唯一 `AutomationRunnerServer`，绑定唯一 Core context；其 `runnerInstanceID` 是该 generation 唯一实例 ID。
2. 同一 server 的 `beginV1Handshake` 获取唯一 reader lease，再 `sendV1Ready`，以一次性 handoff 进入 `serveV1Handoff`。
3. handoff 的 prepare 受同一 deadline/EOF 监视；身份成功且独立政策允许后才准备，EOF 时撤销并取消准备。
4. `RunnerMain.makeAutomationService` 改为接收 server 的 `runnerInstanceID` 和 context；不再为 service 新建 UUID。
5. `BrowserSession.makeAutomationService`、service、controller、`OwnedBrowserAutomationPage.attach` 保持同一 ID 和 context。
6. 不再对正向路径调用会新建 server 的 `service.serve`；同一 server、lease 和 context 进入请求循环。

拟新增 App 内部 `@MainActor BoundRunnerServiceSlot`，不是身份 callback，也不是第二 executor：
- 状态：`created/unbound → bound → closing/revoked → closed`；单次 bind，拒绝重复、跨代和关闭后 bind。
- `bind(service)` 在准备完成后安装既有 service；仅允许同代 context/instance，失败则关闭。
- `dispatch(request)` 只转发已有 `service.handle`；未绑定、已撤销或过期代 fail closed，回调不能授权身份。
- `close()` 先同步阻止新 dispatch、撤销 slot，再等待在途业务与既有 service/page cleanup；防止旧 callback 影响新代。
- server shutdown hook 与 slot 关闭须协调生命周期，避免 retain cycle；cleanup 未确认不得释放原锁并声称成功。

`repositoryPermission` 仍可作额外业务撤权检查；它不替代 kernel/context 检查。
`NSApplication.shared` 位于 `RunnerMain.makeAutomationService`；身份成功不等于可调用，须独立 GUI 政策授权。
还须实施时核查准备链是否有更早的隐式 GUI 构造；fixture、`TEST_ONLY`、字符串/path/Bool 不得绕过当前硬拒绝。
Core 接入不打开 Manager、AppleScript 或输入门禁；最小 GUI smoke 不冒充完整 AppleScript 验收。

## 资源与身份信任边界

`OfflineBundleContract.fixture` 和 `.candidate` 均不能授权新产品；candidate 固定 `sh.safarier.g1probe` 与旧签名二进制及资源哈希，仅属外部旧候选 verifier。
不得把最终主程序或 `CodeResources` SHA 嵌入同一主程序：这是自引用构建。
预审静态契约定义允许 namespace、类型、链接策略及可独立 pin 的资源/helper；生成或签名资源须有另审的非循环 pin 方法。
动态部分由真实 OS 静态/动态 code identity、kernel peer/birth 和固定 provider baseline 核验；baseline 只能检测变化，不能证明初始可信。
本地明确审阅的构建可在将来评估独立固定 artifact 或 code requirement 的有界诊断；分发生产另需 signer/update 策略。
不预设必须购买 Developer ID 或安装工具；当前独立信任方案均未批准，positive App adapter 保持 unavailable。
该未决不阻塞经用户确认的无 GUI Core 模块化及原锁生命周期包。
实际 workspace 使用同一 `SafarierWorkspace.default()` 对象及原 owned launch 约定 pin 的同一路径；bundle/resource 来源与打包布局交叉核验。
`SAFARIER_HOME` 是现有 workspace 定位输入，不是身份或许可证明；不可从 Bundle 父目录推导生产 workspace，亦不可用环境字符串授权。
`JSONDocumentStore.save` 以默认属性创建目录并 `Data.write(.atomic)`；源码不保证 root/locks 为 0700 或 profiles.json 为 0600，不能套用 fixture mode 假设。
保留严格 pin、owner、no-follow、hardlink 和完整文档观测；未知布局或 mode 默认拒绝，不默默 chmod 或迁移真实 Profile 目录。
原子写造成 inode 替换或任何完整文档变化均使原 baseline 失效关闭，不能自动 rebaseline；首次 GUI 可另获授权新建符合约束的可丢弃 workspace，不迁移用户资料。
兼容性未解决时 positive adapter 退出为 unavailable；本计划不扩展为存储系统改造。

## 边界、验收和决策

- 现有 `scripts/build-app.sh` 默认输出 `dist/Safarier.app`，130 行删除 `$APP`，153 行 trap 删除 icon 临时目录；未来须审查全部副作用并另获授权。
- 未来沿原脚本只能使用核实过的全新输出，不触旧 dist 或已安装 App；若不能满足范围则停止，不以新输出掩盖临时删除等副作用。
- 验收：身份成功才准备；失败或 EOF 期间零 GUI 构造；同一 server/lease/context/instance，旧 callback 不生效。
- 验收：自有资源和 page drain 后原锁才释放；人工启动不变；v1、8+2、2+2、262160、4096 不变；testhooks 不入产品。
- 验收须区分 Core 离线、build、package、最小 GUI、输入和完整 AppleScript；G1/G2/G4/G5 在有授权的 GUI 阶段取证，不设循环前提。
- 决策：确认 Core/lease 首包；独立批准正向信任根与 App 适配；之后分别决定 build/package、GUI 和输入授权。
- 不要求 VM、默认 4096 满量或穷尽 EINTR；不以更多同类 CLI 轮次替代真实验收。
