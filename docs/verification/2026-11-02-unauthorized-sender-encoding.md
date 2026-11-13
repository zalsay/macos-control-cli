# UNAUTHORIZED：真实 sender UInt32 编码归因与修复（2026-11-02）

## 结论与范围

**已修复本次真实 Apple Event 能力查询的 UNAUTHORIZED 误拒绝，并经主 agent 三轮实机只读回复验证。** 正式首次启动、通用 Bundle ID 唯一路由、页面输入及 G5 并行输入门禁没有因此通过。

分支 mcc-safarier，HEAD 2f32d21248deaffd8c8c1152a39912aa46350c7e。Terra/high worker 实现；主 agent 唯一执行 code review、独立回归及真实 App/Apple Event 验证。实际 worker turn_context 各阶段均为 gpt-6.1-terra/high；未委派 code review。

宿主 macOS26.6.2(25G83)、Xcode27.2(27B52)。正常已安装App未改，未安装、提交、push或发布。

## 1. 先取得真实拒绝证据

在原私有 fence 副本添加一个 typed forwarding 观察 hook，精确核验实际 SFRAutomationRequestCommand 的 own method、完整ABI、原IMP映像，原self/selector/返回值只转发一次。七个激活/窗口拒绝保护与45秒watchdog始终保留；新请求观察只对已校验trace basename的unauth-diag-前缀启用，控制标签不安装该hook。

只记录主线程/当前命令/Manager上下文布尔值，以及属性存在、类型、长度和值域比较结果，不记录真实UID、sender PID、事件正文或audit token原文。OS currentAppleEvent仅同步借用；主agent检查到辅助函数参数可能引起ARC保留后要求修正，最终两个事件参数均unsafe-unretained，LLVM检查无事件参数storeStrong。

修复前同一二进制SHA f0b7dd1fe6b9c5348df2626c3784bb21b981bbe14ccf6c0b02b76212bba2b837：

| 实际记录 | 控制：不装请求hook | 启用最小诊断 |
| --- | --- | --- |
| label | unauth-control-20261102-2 | unauth-diag-20261102-1 |
| PID | 61111 | 61115 |
| 不提示权限预检 | 0 | 0 |
| Apple Event OSStatus | 0 | 0 |
| 应用回复 | UNAUTHORIZED | UNAUTHORIZED |

因此观察本身没有把失败“测绿”。真实诊断显示：

- mainThread=1、currentIsSelf=1、managerDelegate=1，inactive/accessory/0窗口/无key。
- command.appleEvent与OS当前事件为同一descriptor，两处属性一致。
- **EUID与PID均为typeUInt32，FourCC `magn`（1835100014），精确4字节。**
- audit属性为typeAuditToken `tokn`（1953459054），精确32字节。

原copyCallerProof只允许typeSInt32，因此在读取/比较身份值之前就返回nil。SDK旧注释写SInt32，不能替代本机真实事件的证据；也不能据此泛化接受任意可转换类型。

证据：`/Volumes/RC500/dev/safarier/.build/automation-manager-entry-20261030/traces/unauth-diag-20261102-1.jsonl`，event51–53；以及本轮root-cause.json。

## 2. 沿原实现修复，不改变身份授权策略

生产改动仅：

`/Volumes/RC500/dev/safarier/Sources/Safarier/Automation/AutomationRequestCommand.swift`

在原adapter内加一个私有senderWord helper，仅接受**精确SInt32或UInt32、精确4字节**，按本机Apple Event原始字节无损归一化为UInt32；不调用泛型数值/字符串coercion。UID保留全部32位，PID须在1...Int32.max内才转Int32。audit仍要求原精确类型及MemoryLayout<audit_token_t>.size，先快照再核验。

以下条件全部保留：

- 真实当前Cocoa命令必须为self，主线程与Manager角色检查不变。
- 属性缺失、字符串、typeData、错误长度不接受，没有getuid/getpid等身份兜底。
- 同effective UID、正PID及完整audit token条件不变；负PID、零PID、UInt32超出Int32正范围仍拒绝。
- 原suspend/coordinator/replay/取消/退出流程不变，没有新服务、执行器或公开命令。

这修正的是两种明确wire编码的表示兼容性，不是把任意标签coerce为数字后放行。未移除或跳过身份校验。

该文件原为未跟踪工作，普通git diff不能提供此次增量；worker仅逆向本次块生成重建before副本，并验证其SHA与本轮before.json完全一致后才保存。主agent独立核验并审查phase2-auth-attested.patch，重建副本不冒称事先保存的原件。

最终源码SHA：81bebcd1a01a9c0a063c60f82983129ff1769d92239e5bfdbec4127483fefe1e。

## 3. 回归与负例

仅在原 `/Volumes/RC500/dev/safarier/Tests/SafarierAppTests/AutomationRequestCommandTests.swift` 补充：

- UInt32/legacy/混合编码及高位UID保留。
- missing、字符串、typeData、短/长整数字节拒绝；PID零、负数、UInt32溢出拒绝，Int32.max边界可解析。
- audit nil、错误typeData、31/33字节继续拒绝。
- 安全构造的命令在非当前Cocoa分发上下文仍返回UNAUTHORIZED；合成属性仅测试解码/模型逻辑，不冒充OS provenance。

旧parser实际行为RED：testSyntheticUnsignedAndMixedSenderWords的XCTUnwrap失败；修复后GREEN。另保留早期测试编译错误，不将其算行为RED。

主agent独立运行安全选择的四个原XCTest类：AutomationRequestCommandTests、AutomationScriptTests、AutomationManagerTests、ManagerLifecycleTests，**三轮每轮10项=9通过/1原skip/0失败**。原skip是独立真实GUI生命周期要求，没有新加skip。八组原/新增headless fence测试也独立通过；最终debug App构建exit0且该修复无新增warning。

**未运行完整UI套件**：BrowserWindow、BrowserFixes、DisplayOverride含真实orderFront/makeKey操作；10月30日允许短暂测试窗口的授权是当时时段，不能用于本轮“不干扰”要求。没有删除/弱化这些测试，也不宣称全量344项本轮通过。

## 4. 修复后真实三轮查询

最终同一诊断候选主二进制：

`92b13afaa46b9eb7f6236bfd2fb6ccc870ac9cf2bacc733eb25e73e6b9c9b139`

固定使用原只做false预检的driver-frozen-main（SHA18c131002e2ae1a0626f3d4cae75a29359a9b28a2110773397fe8be1c8d20faf），没有真实true权限请求函数路径；原consent.once仍保留。所有发送使用never-interact/do-not-prompt，只有capabilities。

| label | 请求观察hook | PID | 严格回复校验 / driver | 收尾 |
| --- | --- | --- | --- | --- |
| unauth-control-confirm-20261102-1 | 关闭 | 69137 | validated，exit0 | 普通终止观察完成 |
| unauth-diag-confirm-20261102-1 | 开启 | 69140 | validated，exit0 | 同上 |
| unauth-control-confirm-20261102-2 | 关闭 | 69150 | validated，exit0 | 同上 |

每轮新进程，回复requestID与retained目标PID、manager角色以及backend=unavailable、uiPolicy/coldLaunch=unverified均由原严格validator核验。中间诊断轮真实UIDmatches=1、PIDpositive=1、audit类型/长度正确；两轮关闭请求hook仍成功，证明修复不依赖观察代码。每轮状态均inactive/accessory/0窗口/无key，无显示/激活保护命中，退出无forceTerminate。

这覆盖当前Cocoa公开命令的真实只读执行/异步回复，不等于osascript语言解析、正式BID发现/多Runner唯一接收或页面输入验收。

## 5. 不抹掉启动失败及其它限制

- 修改后的最初两个验证尝试仍在约30秒LaunchServices回调时未finished，未发送capabilities；按已验证owner清理完成。fixed-real-batch-status.json的validatedReplyCount=0被保留，不算身份修复通过证据。
- 随后的owned launch-sample也迟到；主agent成功取得自有PID68427的栈，采样时已进入ManagerGUI.start→NSApplication.run正常事件循环。prelude约在回调附近才出现；**采样不能定位之前约24秒延迟，更不能称首启问题修复。** driver仍exit1，没有放宽timeliness gate去判绿。
- 最终三轮是在上述诊断之后的同构建进程重启，不是三次全新构建/首次安装冷启动。G1继续未通过，正式coldLaunchVerified/Native/Factory/defaultscript门禁保持原状。
- 最终独立observer已等待首样本再启动driver，3000样本覆盖三轮全生命周期，NSApp始终nil；cursor hash确有变化，不宣称鼠标静止。其frontPID仍可能因未泵RunLoop而陈旧，不用常量frontPID证明焦点。没有页面动作，不是G5持续打字/中文IME验收。
- 无VM、全局输入、System Events、鼠标/焦点/IME回位，无自动再授权。一次失败批次的runner hash断言存在无效条件表达式，已另行真实SHA核验；最终通过批次在启动前使用正确严格SHA断言，失败批次不作通过证据。

## 6. 收尾与证据

生产新增修复仅上述adapter和原测试文件；另追加计划和本报告。正常已安装 `/Applications/Safarier.app` Info/主二进制不变；相邻chrome-control-cli、原10个缺失assets和skip-worktree标记不变，无诊断进程残留。未安装、commit、push或发布。

证据根：`/Volumes/RC500/dev/safarier/.build/automation-unauthorized-20261102/`

- before.json、contract.md、root-cause.json、fence/phase2-auth-attested.patch
- fence/test-phase2-red-behavior.log、main-final-safe-tests-summary.json、main-fixed-fence-tests.log
- final-fixed-app-build.log、fixed-candidate-review.json
- diagnostic-batch-1-status.json、fixed-real-batch-status.json、fixed-owned-startup-sample.log
- fixed-confirm-batch-status.json、main-verification-summary.json、final-audit.json
- stack：`/Volumes/RC500/dev/safarier/.build/automation-manager-entry-20261030/driver/samples/unauth-control-fixed-stack-20261102-1.txt`

