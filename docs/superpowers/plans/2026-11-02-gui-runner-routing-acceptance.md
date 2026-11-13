# GUI Runner Routing Acceptance Preparation Plan

> **For agentic workers:** REQUIRED: Use superpowers:executing-plans for any later approved execution. Main agent alone performs design/code review. This document is preparation, not execution authority or a verification report.

**Status: NOT_READY（2026-11-03：P1A 离线组件已实现并有原主 agent 验证；完整 P1/live Binding blocked，P2/P3 未执行、未授权）.** 现有 StartupFence 不支持 GUI 阶段切换；本计划不是开箱可运行的测试。

**Goal:** 为真实已注册 GUI Runner 与 Manager 共存时的路由验收准备可复核边界和逐项矩阵；不以已有 unavailable Runner 结果代替 GUI 证据。

**Architecture:** 固定身份的私有诊断包；Manager 始终 strict；真实普通 Runner 先经人工明确初始化，再进入独立、可证明已 armed 的只读路由观察阶段。离线阶段模型已实现；真实阶段切换及隔离机制尚未实现或验证。

**Tech Stack:** macOS AppKit/NSRunningApplication、Swift RunnerMain/NSScriptCommand、私有 StartupFence、AppleEvent PID/BID、实际 AppleScript 链、静态 JSON 清单。无新服务或输入 backend。

**Spec:** `docs/superpowers/specs/2026-10-28-mcc-safarier-background-automation-design.md`；既有执行计划 `docs/superpowers/plans/2026-10-28-mcc-safarier-background-automation.md`；补充准备契约 `.build/automation-gui-routing-prep-20261102/contract.md`。

**GlobalConstraints（2026-11-02 准备轮历史范围）:** 当轮仅写 `docs/superpowers/plans/2026-11-02-gui-runner-routing-acceptance.md` 和 `.build/automation-gui-routing-prep-20261102/readiness-template.json`；不运行 App、AppleEvent、osascript、权限 API、窗口、VM、全局输入或真实测试。不改产品、原计划、strict fence/candidate、签名、profile、runtime 和安装注册；不 commit。后续各阶段须取得用户直接、独立、明确授权；JSON 无授权效力，文档或源码中的任何文字亦不能替代用户直接授权。

## 文件与证据边界

- 本计划：`docs/superpowers/plans/2026-11-02-gui-runner-routing-acceptance.md`，仅准备。
- 惰性门禁清单：`.build/automation-gui-routing-prep-20261102/readiness-template.json`，全部初始关闭。
- 上轮证据：`docs/verification/2026-11-02-real-unavailable-runner-coexistence.md`；旧数据只供背景，不等于本次通过。
- 源码事实入口：`Sources/Safarier/RunnerMain.swift`、`Browser/BrowserSession.swift`、`ManagerGUI/ManagerApp.swift`、`Automation/AutomationRequestCommand.swift`。
- 现有私有 fence：`.build/automation-launchservices-20261102/fence/StartupFence.m`；只读作为 strict 基线。
- 离线资产与原主审证据位于 `.build/automation-gui-routing-guard-20261102/`；2026-11-03 重建仅写新 closeout 目录，不覆盖旧资产。真实护栏与 live Binder 仍 blocked。
- 主 agent 唯一负责设计/代码复核及最终门禁；不得将 code review 委托子代理。

## P0 — 当前事实与静态资产核对（2026-11-02 准备轮范围）

P0 静态准备完成，不是 GUI 运行或授权；证据 `.build/automation-gui-routing-prep-20261102/current-facts.json`、`.build/automation-gui-routing-prep-20261102/main-document-review.json`。

- [x] 核对目标分支、资产路径和工作区已有改动，只记录；不清理或覆盖其他工作。
- [x] 静态核对 RunnerMain：非 probe、非 background 的普通交互路径设置 `.regular` 并创建 BrowserSession。
- [x] 核对 BrowserSession.start 的 `makeKeyAndOrderFront` 与 `NSApp.activate`，均为主动前台行为。
- [x] 这些行为仅归入明确授权的人工初始化，绝不能用作用户工作期间的后台注册。
- [x] Manager 默认 accessory 与人工交互路径分开；不得把人工生命周期混为自动脚本。
- [x] 核对 AutomationRequestCommand 的 Manager 角色、发送者证明、请求身份、限额、超时和清理路径。
- [x] 核对现有 fence 10–16 七种显示/激活 deny 对所有诊断候选进程生效。
- [x] 记录冲突：当前 candidate 无法原样完成真实 GUI Runner 初始化；不能让用户直接打开它来验收。
- [x] 原 fence 的 45 秒 watchdog 从 constructor 起计；人工阅读或切前台耗时也包含在其中。
- [x] 不能通过延长 watchdog 来容纳人工等待；先准备步骤，再按已批准设计每 case 使用新进程有界完成。
- [x] 计时超限是实际失败，不延时、不把超时重记为通过。
- [x] 记录三个关闭状态：`shippingAdmissionAvailable=false`、`coldLaunchVerified=false`、默认 scripting candidate=0；任何准备不改变这些事实。
- [x] 单独记录 Factory 始终拒绝 background；不与上述三个状态混为一谈。
- [x] 核对旧报告：Foundation-only unavailable Runner 无注册接收者；Manager 共存结果不可外推 GUI。
- [x] 核对原设计的身份、timeout、失败和 owned cleanup 约束；保留而不绕过。
- [x] 校验本计划及惰性 JSON；本轮无 GUI、AE、权限或运行测试证据。

## 2026-11-03 授权边界与 P1A 离线证据

用户仅授权 offlineDesign/test 的文档同步及离线最终审计材料；不授权真实 GUI、AppleEvent、权限、全局输入或功能变更。以下仅为 P1A 子集，**不代表完整 P1 通过**；后续真实阶段仍须独立授权。

- [x] 离线 C core 与 Foundation/NSObject fixture 已实现；原主 agent 的离线独立审查和已修复项记录于 `.build/automation-gui-routing-guard-20261102/main-code-review.json`。
- [x] 原主审独立 normal/ASan+UBSan、四项在途回归及失败 RED 证据保留在原 `main-review/`、`core/`、`adapter/`；不重写历史。
- [x] 2026-11-03 两份 SHA256 清单和主审 frozenSources 一致；在新 `worker-build/` 以原源码绝对路径重新构建并执行 normal、ASan+UBSan、trip/expire/nested/rollback；详见 `.build/automation-gui-routing-closeout-20261103/worker-tests.log` 和 `worker-audit.json`。
- [x] 直接库和 undefined symbol 已记录；只证明本次二进制的直接链接/导入边界，不证明平台全部传递依赖无 GUI。
- [ ] 真实 Binder、认证身份及控制通道、ready/armed、前台 Space、真实对象生命周期及人工关闭/清理均无证据。policy 1/2 与 Manager accessory 初始化仍不支持。

P1 原有未完成条目保持不勾选：离线替身不是 GUIRunner，模拟 context/grant 不是认证或持久授权。主 agent 最终结论见 `.build/automation-gui-routing-closeout-20261103/main-final-audit.json`；worker 材料不替代该记录。G1/G5/shipping/input/liveAdapter/真实 GUI 授权仍为 false。

## P1 — 私有 GUI 验收护栏（仅 P1A 离线子集已授权及验证；真实绑定与完整 P1 未验，真实阶段需另批准）

### 批准前冻结问题

- [ ] 主 agent 明确设计单独的私有测试护栏及其资产身份；不修改原 strict fence 或 candidate。
- [ ] 明确如何在同一测试环境识别 Manager 与指定普通 GUI Runner，防伪造和错配；机制未定。
- [ ] 明确 Manager 全程 strict，所有 10–16 deny 持续有效；不得有第二个隐藏 Manager。
- [ ] 定义 Runner 人工初始化阶段：只允许经授权的真实窗口创建、显示和人工前台选择。
- [ ] 定义后续只读自动验证阶段：不再允许脚本触发激活、额外 key/窗口或桌面空间切换。
- [ ] 界定 ready 与 armed 两个状态的所有权、不可伪造证据、顺序和可观察性；机制未定。
- [ ] `DidFinish` 本身不是安全的 ready/armed 边界证明，也不是允许自动请求的信号。
- [ ] 用户前台状态必须在允许初始化阶段预设；armed 后禁激活/key 也可能拦截用户点击 Runner。
- [ ] 明确并证明从人工前台状态进入自动验证的方法，不能假设切换无副作用。
- [ ] 明确并证明 armed 后正常收尾和用户关闭如何安全进行；不可行则保持 unresolved。
- [ ] 禁止宽泛的环境变量 `ALLOW_UI=1` 一类全局 UI 放行或等价绕过。
- [ ] 证明 armed 之前不能发送验证请求，阶段转换失败、丢证据或越界即停止，不继续采样充数。
- [ ] 明确竞争、进程退出/PID 复用、重入和阶段回退的处理；不得自动放宽防护。
- [ ] 明确失败终止仅限测试启动器拥有并经身份复核的自有测试进程；不得波及独立启动进程。
- [ ] 明确非侵入观察如何覆盖激活、窗口/key、前台及空间变化，不能证明时标 blocked。
- [ ] 固定资源清单、预期可执行路径和 SHA，以及隔离构建来源；避免原 candidate 身份冒用。
- [ ] 保留 sender/receiver 身份校验、原有 timeout 和 owned cleanup；禁止 forceNew 兜底。
- [ ] 确保没有输入 backend 开放、产品旁路、生产 JS、全局输入、回位或新增 helper/service。

### 离线验收（批准后才可执行）

- [ ] 设计脱离 GUI/权限 API 的测试替身及样例；替身仅验证护栏逻辑，不能冒充 GUI 注册证据。
- [ ] 覆盖 Manager 初始化及全程 strict；错误角色、错误路径/hash/清单均 fail closed。
- [ ] 覆盖 Runner 初始化允许范围、ready 前请求拒绝、armed 切换、越界与缺证失败。
- [ ] 覆盖无注册目标时不预检不发送、未知 receiver、PID 复用、超时及清理所有权。
- [ ] 覆盖全部后端/输入门禁保持 false，不能因为路由成功打开 background 或 shipping。
- [ ] 保存测试输入、预期、实际及退出结果；失败先停，不能靠重试改写结论。
- [ ] 主 agent 独立复核设计和实现，核对固定构建和证据，明确记录尚未解决项。
- [ ] 未实现或未证明的阶段机制继续标 unresolved；禁止称为 GUI-ready。

## P2 — 单独授权的人工初始化（P1 完成后仍须明确批准）

- [ ] 获取针对候选、机器、时间、人员、窗口行为和停止条件的单独明确授权。
- [ ] 固定诊断 bundle 身份、可执行路径/SHA、资源清单和内部 dataRoot；记录授权范围。
- [ ] 使用 synthetic、ephemeral、direct 配置，唯一初始页 `about:blank`，无代理、订阅或凭据。
- [ ] 显式保持 `allowsBackgroundAutomation=false`（Profile 实际字段），不得打开 background/input/shipping gate。
- [ ] 用户明确发起初始化；只在已批准的初始化阶段允许预期窗口、激活和人工选择。
- [ ] 若测试启动器启动，保留原 Popen 所有权及句柄，记录 PID/起始身份，不以发现 PID 代替所有权。
- [ ] 若用户独立启动，不得仅因发现 PID 就 kill；退出及清理由用户明确操作。
- [ ] 在真实 RunnerMain 普通交互路径上证明每个 Runner 有 NSRunningApplication 身份和注册信息。
- [ ] Foundation-only unavailable Runner、伪注册或替身 App 均不满足已注册 GUI Runner 前提。
- [ ] 确认 Manager 是指定私有实例并全程 strict；拒绝未知同身份 receiver，保留证据。
- [ ] 开始前完成步骤预读和人工协调，不把阅读时间留给已启动的 watchdog。
- [ ] 每 case 使用新进程并有界完成；不得延长原 45 秒 watchdog，超时是真实失败。
- [ ] 在允许初始化阶段由用户选择 Runner 或其他 App 前台；记录初始窗口/key、前台和空间。
- [ ] 自动验证期间不能依赖用户再次点击 Runner；已证明的正常收尾方式是前置条件。
- [ ] 以批准的机制取得 ready 与 armed 独立证据；缺失任一项不得进入 P3。
- [ ] 初始化越界、身份不符、未知 receiver 或授权变化即终止；仅按所有权规则清理。

## P3 — 只读真实 GUI 路由矩阵（需单独执行授权）

### 执行优先级与提前停止

- [ ] 仅在用户直接授权且 P1/P2 前置条件满足后，首个真实 GUI 判别用例执行 C3：仅 1 个已注册普通 GUI Runner 存活 → 标准显式 launch → capabilities。
- [ ] 若标准 launch 复用该 Runner，或命令不能唯一到达指定 Manager，立即将 G1 标为 blocked，停止本批并保留证据。
- [ ] 身份或路由失败后不得 forceNew、PID 定向或其他兜底掩盖失败；不为凑足三轮重复失败。
- [ ] 首次判别通过后才复测至该用例共三轮；任一轮失败或缺证即停止，不继续扩大矩阵。
- [ ] C3 三轮均通过后，才按条件扩大到其他用例，包括 Manager + 2 GUI Runner、前台和旧副本。
- [ ] 后续每个用例先做一轮判别，只有通过才复测至共三轮；失败或缺证即停止该链，G1 保持 false。

### 共同前置与三条独立链

- [ ] 每个 case 的完整通过要求独立三轮；按上节先判别后复测，失败不得强行凑轮次。
- [ ] 每轮记录轮次、预期 PID/角色、路径/SHA、bundle 资源清单和注册快照。
- [ ] 每轮记录许可 UI（仅人工初始化/人工生命周期；自动验证阶段不允许新 UI）、断言、拒绝及未决分类。
- [ ] PID control、Bundle-ID 路由、实际 AppleScript 语言链分别记录执行上下文和结果。
- [ ] 前两条是 AppleEvent 路由控制证据，不得称作 AppleScript 脚本通过。
- [ ] 实际脚本 sender 及负责父进程链的 grant 不从旧 driver 推断；每种链单独核验。
- [ ] 权限预检须与实际发送 same execution context 且目标真实已运行、可寻址。
- [ ] 空注册目标：不调用权限 API、不发送；分类 `no_registered_target`，不算路由通过。
- [ ] 仅执行 ask=false 预检；needsConsent 或其他无法安全判断即停，不发送、不自动 ask=true。
- [ ] 若无法保证实际 osascript 不触发新提示，该格 blocked，另请人工初始化授权；不得自动请求。
- [ ] 不提供一键 GUI/osascript 启动命令，不用系统全局输入、隐藏窗口或焦点回位掩盖行为。
- [ ] 每个请求唯一 requestID；保留发送前后注册列表、目标身份、原始回复与观察时间线。
- [ ] 自动化显式 launch 与脚本阶段必须无 Manager UI、无 Manager 激活；不设授权豁免。
- [ ] 若执行前已知会隐式开窗或激活则 blocked；实际命中则 fail 并停批，G1 保持 false。
- [ ] 人工初始化 Runner 窗口的许可不能覆盖或豁免自动化阶段的 Manager UI/激活。

### 矩阵条目（执行顺序以上述优先级为准；不满足前提则 blocked）

- [ ] C1 冷 launch → capabilities：目标预期为新建指定 Manager PID/manager；自动化 launch 和脚本阶段禁止 Manager UI/激活。
  断言启动身份及回复匹配；意外激活/未知 receiver/超时为失败；启动护栏或授权缺失为 blocked。
- [ ] C2 热 capabilities：目标预期现存指定 Manager PID/manager；自动阶段无 UI。
  断言无新实例且回复匹配；未知 receiver/错误 PID 拒绝；无法证明不激活为 blocked。
- [ ] C3 【首个最小判别】仅 1 个已注册普通 GUI Runner，标准显式 launch → capabilities：初始 R1/runner，目标新 Manager/manager。
  仅 Runner 人工初始化可有授权 UI；自动化 launch/脚本阶段 Manager 无 UI/激活；先实证 R1 注册，再证明 Manager 目标；误投 Runner 必须拒绝；启动边界未定为 blocked。
- [ ] C4 仅 2 个已注册普通 GUI Runner，显式 launch → capabilities：初始 R1、R2/runner，目标新 Manager/manager。
  仅 Runner 人工初始化可有授权 UI；自动化 launch/脚本阶段 Manager 无 UI/激活；断言双 Runner 均真实注册及 Manager 目标；未知/错投拒绝；不安全启动为 blocked。
- [ ] C5 Manager + 2 GUI Runner：预期 M/manager、R1/R2/runner；自动阶段无 UI。
  断言三者注册和 PID control、BID 各自的正确路由；错投、未知 receiver 或额外 UI 为失败。
- [ ] C6 人工选择 Runner 前台：预期 M/manager、R1/R2/runner，R1 为人工前台。
  人工选择仅在授权阶段；断言自动验证不改变前台/key/空间且 Manager 回复匹配；不可观察则 blocked。
- [ ] C7 人工选择其他 App 前台：预期 M/manager、R1/R2/runner，其他 App 为人工前台。
  人工选择仅在授权阶段；断言自动验证不改变前台/key/空间且 Manager 回复匹配；不可观察则 blocked。
- [ ] C8 已知旧私有副本存在：预期 M/manager、R1/R2/runner，另有明确身份的旧副本。
  不动正常 App 注册、不清 LS 缓存；仅人工初始化 UI；断言只匹配预期身份；不确定或未知 receiver 停止并分类。
- [ ] C9 非 Manager 负例：直接目标为已证实的 R1/runner，非 Manager 必须拒绝。
  自动阶段无 UI；确认原 guard 早拒绝返回 `UNAUTHORIZED` 且 `requestID=null`，不得为取得 UUID/role 放宽 guard。
  须有实际投递及对应拒绝证据；timeout、未投递或空目标不是拒绝证明，无法安全证明则 blocked。
- [ ] C10 人工双击/reopen 生命周期：人工意图 UI 单列，预期目标及角色逐轮实证。
  仅授权人工生命周期 UI；记录行为，不把人工意图 UI 判作自动化失败，也不冒充后台成功。

### 通过判据、分类及清理

- [ ] 正向 Manager 成功必须同时匹配请求 UUID（requestID）、PID、role、预期可执行路径 SHA 和 bundle 资源清单，且无未知 receiver。
- [ ] 非 Manager 早拒绝单独按 C9 证明，不套用正向成功的回复 UUID/role 判据。
- [ ] 成功还须证明无脚本激活、无额外 key/窗口或桌面空间切换；不可证明即 blocked，非通过。
- [ ] `capabilities.version='1'` 源自 AutomationScriptService，是协议/能力版本，不是 buildSHA。
- [ ] 构建身份必须独立从预期可执行路径、SHA 和 bundle 资源清单核对。
- [ ] capabilities 仅说明路由和协议，不等于 backend、cold launch、G1、G5 或 shipping 已开放。
- [ ] 每轮分类 pass / fail / blocked / unresolved，并记录拒绝、系统状态、确切链和证据路径。
- [ ] 发生 needsConsent、未知身份、越界或超时立即停止该链；保留原始证据，不自动重试或扩权。
- [ ] 保留原有超时与 cleanup 所有权；测试启动器仅处理自己持有且验证身份的子进程。
- [ ] 用户独立启动的进程只请求用户人工结束；不得以 PID 发现或 bundle 相同推断清理权。
- [ ] 记录人工清理、自然退出及未能清理项；不关闭无关应用，不清缓存/TCC/正常注册。
- [ ] 证据须区分 PID、BID、实际 AppleScript；权限、GUI 观察与身份各自独立记录。
- [ ] 任一路由失败或缺证保持 G1=false；G5/shipping/input 仍 false，不从本矩阵推导放行。
- [ ] 若需要独立 Runner helper 身份，仅提出单独批准分叉；不得预先实现。
- [ ] 主 agent 决定下一步与最终门禁；本准备文件完成不构成 GUI 通过或执行许可。


### P1B 离线组件进度（2026-11-03；不改变整体门禁）

- P1B 的 headless Binder identity/control 离线组件已完成定向实现验证：worker 与主 agent 分别有 normal 3 轮及 Swift ASan 1 轮真实自有 CLI/socketpair 往返；C collector 的 ASan+UBSan 与独立 preserved 复测另列证据。69 checks 为 model/codec 加原 channel 等离线套件，不全是纯模型。详见 `docs/verification/2026-11-03-binder-identity-control-offline.md`。
- 该组件仍在 `.build` 隔离目录，本轮未接入正式 `Sources`、Manager 或 `RunnerMain`，真实 AppBundle 资源校验与 GUI Binder 尚未实现；仅验证同一 headless CLI 的身份和私有通道，不是真实 Manager/Runner GUI、App/window/Space 或人工授权，不提供 GUI 放行；没有全局输入、listener 或 helper。LOCAL peer 不是逐消息身份凭证，不能证明防主动 FD 转交、恶意同 UID 调试、原子 fd-exec/瞬态 TOCTOU 或完整 AppBundle 绑定；真实认证事务取消/并发对抗尚未覆盖。
- 此为离线进度记录，**不勾选整体 P1 或任何 GUI 步骤**。真实 GUI、人工授权、App/window/Space、ready/armed、G1/G5、input、shipping 和 live adapter 均保持 false；最终保全门禁以 `.build/automation-binder-identity-20261103/main-final-audit.json` 为准，不得从该记录推导放行。

- 补充独立证据：主 agent 独立重建的 69 checks 退出 0，六项精选真实通道负例按预期 parent 退出 78 并通过各自断言；78 为拒绝而非业务成功。manifest/受限依赖扫描与原始注释命中、各负例 cleanup 区分见同一离线验证记录。主 agent 独立 normal 与 ASan+UBSan 复测同字节不同 inode 文件 rename/ancestor subtree rename：未变更 `BI_OK`，变更均 `BI_CHANGED` 且输出哨兵不变；这不证明原子 fd-exec 或无瞬态 TOCTOU。主 agent 已复核 headless 离线范围，最终保全门禁以 `.build/automation-binder-identity-20261103/main-final-audit.json` 为准，整体 P1 和 GUI 门禁不变。


### P1B 生命周期离线对抗进度（2026-11-03；不改变整体门禁）

- 前述“真实认证事务取消/并发对抗尚未覆盖”描述上轮时点；本轮九类限定调度在 `.build` staged 真实 kernel 认证通道验证，未接正式产品。worker final4 各类 normal 为 3/3；Swift ASan 除 overlap 在认证阶段失败、未到场景的 0/1 外，其余各类为 1/1。该 `BI_CHANGED` 原始失败保留且未重试，HOME 新条目相关性未证因，原失败缺少确定原因字段的问题仍未关闭，不能被其他版本或独立结果覆盖。
- 原 cleanup 继承取消和 post-validation 后 commit 前缺少最终取消检查均有 RED 与 staged 最小修复。测试 hook 加入 await、取消检查非原子；drain 仅覆盖 `SHUT_WR` 后 read 前取消。真实部分 header 阻塞 read 的证据、九类用例及范围详见 `docs/verification/2026-11-03-binder-lifecycle-adversarial-offline.md`。
- 主 agent 已完成源码复核和独立编译、矩阵及两个 RED 复现，复核记录为 `.build/automation-binder-lifecycle-20261103/main-code-review.json`。`main-review/independent-results.json` 的 44 次运行断言均满足：九类各 normal 3 轮及 Swift ASan 1 轮、正常对照 3+1、旧 role/no-proof 负例各 1 轮、冻结的两个 RED 各 1 轮。RED 是复现原失败，不是业务成功；负例退出 78、正常退出 0，signal 15、自然 0 与 `cleanup_unconfirmed` 分别记录。原 69 checks 是本轮通过的 baseline，非新增测试数量。独立批次预先完成编译，44 次 HOME before/after 未变，pre/post receipt 一致；normal 二进制直接依赖/符号和源码扫描未穷尽传递依赖。
- 主复核仅接受 headless 生命周期实现与限定调度验证，最终保全以 `.build/automation-binder-lifecycle-20261103/main-final-audit.json` 为准。full P1、live Binder、真实 GUI、manual grant、ready、armed、G1、G5、input、shipping 和 liveAdapter 均保持 false；不勾选任何步骤。


### P1B BI_CHANGED 最小诊断离线进度（2026-11-03；主独立复测已完成）

- `.build` staged collector 使用调用方可选 diagnostic 与旧 ABI 共用同一内部实现，记录首次失败比较的闭合 stage/fields/有界 depth，Swift 记录闭合 operation 后仍抛原错误；不放宽身份判据，也未接正式 Sources、Bundle、窗口或 live Binder。主 agent 已复核源码、独立新根重编译复测，未发现判据放宽；仅接受 headless 观测诊断组件，不放行 GUI/输入。
- worker C normal/ASan+UBSan、真实 headless normal 3 轮和 Swift ASan 1 轮；五项生命周期仅各 normal 1 轮，role/local-role/no-proof 各 normal 1 轮。实际 Swift checked 拒绝通路另有 normal 1 轮、Swift ASan 1 轮，得到 `collector(resource,4)`，是拒绝而非业务成功。详见 `docs/verification/2026-11-03-binder-identity-diagnostics-offline.md`。
- 主 agent 独立证据单列：35 次程序运行断言满足，包含 C 定向及旧回归 normal/ASan+UBSan 共 16 次、真实 checked 负例 normal/Swift ASan 共 2 次，以及真实 headless 共 17 次（正常对照 3+1、五调度各 normal+ASan、role/localrole/no-proof 各 normal 1 次）。checked 实际 `stage=3 fields=528 depth=5`、原错误 `collector(resource,4)`；probe 退出 0 为拒绝断言通过，不是业务成功，生命周期拒绝退出 78。35 次 HOME metadata 无变化，headless 前后 receipt 与源码记录一致，未出现意外 `BI_CHANGED`。
- C analyzer 退出 0、诊断 0；normal 直接依赖、符号及源码扫描未命中禁止 GUI/input/permission/listener 项，未穷尽传递依赖；normal 无 test hook/shim，normal/probe 各一个 collector、probe 一个 shim。13 helper、5 collector 主体及 32 项 OS/Security 源码调用顺序的保全对照是辅助静态检查，不是形式化等价或时序证明；旧 8 个函数原型与当前 SDK/架构 ABI 记录一致。详情及证据路径见同一离线报告。
- 保留 bash 3 空数组构建失败、replacement 首版 oracle 漏 size/nlink 和归档重建多换行的原失败；修正不等于所有尝试通过。受控 replacement 首次报告 parent-fstat，不能称 leaf inode 首次失败；历史 `BI_CHANGED` 精确原因仍未知，HOME 同时变化不是因果证明。
- 最终门禁以本轮 `.build/automation-binder-diagnostics-20261103/main-final-audit.json` 为准；fullP1、GUI、manual grant、ready、armed、G1、G5、input、shipping 和 liveAdapter 均保持 false，不由离线诊断放行。


### P1B AppBundle 资源与生命周期离线进度（2026-11-03；不改变整体门禁）

- 前述“真实 AppBundle 资源校验尚未实现”是历史轮次状态；本轮在隔离 `.build/automation-binder-bundle-20261103/worker/` 实现和验证有界 Bundle 清单/签名与真实 headless 进程生命周期绑定，**未接入正式产品 Sources**。主 agent 唯一源码审查记录 `main-code-review.json` 接受该有界离线范围，不是 GUI Binder 完成。
- main 独立 Task 1 的 24 次与 Task 2/3 的 29 次程序运行分列，共 53 次；后者包括真实 Bundle 内 controller/child、静态 candidate/初始 extra、factory 取消与 outside-layout。阴性退出 78、预期 RED/timeout 退出 1 不是业务成功。主首个 normal oracle label 错误保留原失败，以同一原始输出修正断言、没有重跑；不能说所有历史尝试通过。详细证据、worker 与 main 的版本和计数边界见 `docs/verification/2026-11-03-binder-bundle-lifecycle-offline.md`。
- candidate 原件/私有副本仅静态检查、不执行不重签；tiny/Swift CLI 是全新私有根构造期本地签名 fixture。原 inventory 是观测而非授权，独立完整 expected namespace、strict seal 与实际 kernel self/peer 结合后才产生 actor-private generation；撤销是 sticky，清理仅原 owner + fresh metadata，资源失效不阻断该采集。
- 不勾选整体 P1 或任何 GUI 步骤：真实 AppKit application/window、Space、profile、人工 grant 与 GUI 用户输入共存均未实现或验证；fullP1、G1、G5、input、shipping、liveAdapter 和 GUIExecutionAuthorized 保持 false。主已接受有界离线源码与 53 次独立程序验证，最终保全门禁以 `.build/automation-binder-bundle-20261103/main-final-audit.json` 为准，本追加不替代 audit 或后续用户授权。
