# 私有 GUI 路由护栏：离线核心与替身适配设计

日期：2026-11-02；范围：用户已确认的私有护栏具体设计与离线验证。2026-11-03 仅对现有组件进行离线复验和文档同步，不包含新设计或实现。

**状态（2026-11-03）：离线核心与 NSObject 测试替身已实现并经原主 agent 验证；完整 P1 和 live Binding 仍 blocked。不是 GUI-ready，不构成开窗、AppleEvent 或新权限授权。** 本文不修改原产品架构或输入准入。

## 1. 原实现与本轮边界

- 原 `StartupFence.m` 在候选 constructor 中安装七个固定显示/激活拒绝 wrapper（event10…16），并保留45秒 watchdog；该 artifact 不支持普通 GUI Runner 初始化。本轮原文件与已签名候选不变。
- `RunnerMain.start` 的普通路径和 `BrowserSession.start` 会 set regular、makeKeyAndOrderFront、activate。只能在未来单独明确授权的初始化阶段发生，不得用来后台注册。
- 仅提取/延续原七种 effect 分类、ABI/own-method/来源验证思想，在独立 `.build/automation-gui-routing-guard-20261102/` 实现离线策略与 fixture dispatcher；不是第二套页面输入器、浏览器或服务。
- 无 NSApplication/NSWindow、AppleEvent、权限预检、GUI注册、osascript、签名/安装、VM或全局输入。没有 constructor 自动装载、监听端口、环境变量放行或任意 selector 接口。

## 2. 阶段模型

| 阶段 | Manager | GUI Runner 的离线模型 | 只读探测决策 |
|---|---|---|---|
| Locked | 七种 UI effect 全拒绝 | 全拒绝，等待绑定的一次性模拟 grant | 不允许 |
| ManualInit | 永不可进入 | 仅绑定 app/window 的七种已知 effect，有限预算和期限 | 不允许 |
| ReadySealed | 以 accessory/inactive/零窗口/无key 的完整观测封存 | 以单窗口/regular/已选前台状态的完整观测封存 | 不允许 |
| ArmedReadOnly | 继续禁 UI | 继续禁 UI，不能回初始化阶段 | 仅可返回只读资格判定，不发送任何请求 |
| Cleanup | 禁 UI，只判定自有 context 可否终止 | 同左；不转发UI操作 | 不允许 |
| Failed / Closed | 不可恢复放行 | 不可恢复放行 | 不允许 |

受限 UI 的实际尝试一旦越阶段或越界就进入 sticky failure；不能先拒绝，再因新 grant 重新进入初始化。无副作用的资格查询可以返回 false，不等同已经发送命令。失败原因不得被 cleanup 或后续消息覆盖。

## 3. 观测与授权的证明边界

核心只比较预期值与 fixture 提供的观测，**不认证真实内核身份、不证明用户授权，也不读取系统前台或窗口状态**。生产或脚本入口不链接该模块。

不可变 context 包含角色、PID/父PID、UID、进程 birth、程序/资源摘要、测试 profile 标记、app/window标记、owner context 与预先选择的前台状态。每次操作重新匹配；PID相同但 birth 不同仍拒绝。

Manager 没有窗口，绑定 window 应为0；GUI Runner 必须绑定一个非0窗口。Manager 必须是具体 accessory 策略，不能用“非regular”冒充。Runner 前台/其他App前台分别建模，不一律要求Runner active。

Ready 的所有字段必须已知且匹配：角色、对象、真实注册的观测标志、启动已完成、无待完成初始化/模态、窗口数量、具体policy、active/key和用户预设的前台状态。DidFinish 单独不够。Seal 必须在没有转发中的 effect 时执行，并立即撤销初始化许可；Arm 另需同一 context 的匹配观测。

**未实现且仍阻塞实际 GUI 的 live Binder：**原始系统事实采集、实际内核/父子身份与同上下文通道证明、真实 profile/URL/构建验证、强持有对象防指针复用、前台/Space可靠观察、用户初始化授权来源、可靠 ready/armed通信，以及正常人工关闭和失败终止的真实行为。不能把fixture匹配struct叫作不可伪造认证。

## 4. 期限、嵌套与所有权

- 使用可信 adapter 输入的单调uint64纳秒；核心不读系统时钟。时间倒退、加法溢出、到达期限即拒绝。
- 总生命周期严格小于45秒；模拟初始化严格小于10秒，最多32次 effect，嵌套深度最多8；不能刷新预算或期限。数值是保守离线设计界限，不是已验证真实GUI耗时；不是延长原watchdog。
- enter/leave票据绑定实例epoch、序号、目标与effect，必须LIFO；跨实例、重放、错序或错误对象拒绝。跨实例标记即使context相同也不复用。
- 有调用在途时不能 seal/arm。真实 wrapper 必须在同步返回路径归还票据，不能先批准后异步转发。
- 清理仅返回原owner/self context的资格，不执行kill、NSApp.terminate或其他副作用；错误owner、PID复用、未知对象不能借清理获得操作权。
- 实际系统退出导致的窗口/焦点行为没有离线证据；不能据此承诺真实cleanup不干扰。模块销毁要求调用方已停止并发使用。

## 5. Fixture-only Objective-C 适配

离线适配器只对自定义 NSObject 测试类安装七个固定selector，normal 测试二进制直接依赖 Foundation、CoreFoundation、libobjc 和 libSystem，不直接链接 AppKit/WebKit；这不证明所有传递依赖均无 GUI。禁止对系统类安装hook，也不构造应用、窗口或光标。

沿原护栏检查方法是否本类拥有、返回/参数ABI、IMP来源与重复安装。必须先验证整个固定表；unknown/inherited/错误ABI/来源或绑定不符则拒绝。允许的同步调用只转发原fixture IMP一次，保持参数/返回值；拒绝或失败不转发。替身的嵌套调用仍受核心栈与预算限制。

这不证明实际AppKit方法的runtime绑定/来源/嵌套行为。真实类hook、constructor、控制通道和被测App打包一律不在本次交付中。

## 6. 本轮验收与不能推导的结论

- TDD保存红绿和故障注入；主agent独立编译、普通测试及ASan/UBSan，核对新文件与旧artifact/hash不变。
- 覆盖七种effect×阶段、Manager无初始化许可、模拟grant错配/重放、缺观测、前台两种状态、错误identity/birth/owner、期限/溢出、预算/嵌套、票据重放/跨实例、seal/arm在途拒绝、清理边界。
- fixture适配器验证允许时原IMP正好调用、拒绝不调用、参数/返回值和嵌套/错误ABI/来源/非主线程；不把替身叫真实Runner。
- native/input/shipping/live-adapter准入函数恒false。离线核心验证通过也不使GUI授权、实际身份/阶段证明、G1/G5或产品能力变true。
- 本轮仅授权文档与离线审计；live Binder 和真实 GUI 初始化未授权且未执行。
- policy 1/2 不支持，Manager accessory 初始化缺口未覆盖；grant 仅限单状态实例，不是真实持久授权。外部并发改 IMP 无原子 CAS；Foundation/ObjC 无完整泄漏证明。超时或 trip 无法撤销已发生的 effect。
- 原主审记录及红绿证据见 `.build/automation-gui-routing-guard-20261102/`；2026-11-03 重验单独记录于 `docs/verification/2026-11-03-offline-gui-guard-closeout.md`，不冒充最终主审。
