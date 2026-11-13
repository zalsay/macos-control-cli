# 真实 unavailable Runner 共存与 Bundle ID 路由验证（2026-11-02）

## 结论：当前关闭门禁分支通过，不能外推到人工 GUI Runner

使用同一私有诊断 App 的**真实 RunnerMain 进程**，不是角色 mock、替身 App 或手动注册进程。完成三个完整新进程周期：每周期先起两个 Runner，测仅 Runner 存活，再启动 Manager 并测 PID/BID 路由，Manager 退出后再次测仅 Runner 存活，最后关闭两个自有通道并观察 Runner 自然退出。

- 六次“仅 Runner 存活”观察中，两个 Runner 的 handshake、capabilities RPC/心跳与进程身份均有效，但同 BID App 注册列表为空。工具不做权限预检、不发 AppleEvent、不隐式启动 Manager，记录 `no_registered_target`；这不是成功的 Manager 路由，也不是已投递 Runner 并获拒绝的证据。
- 三次 Manager 与两个 Runner 共存时，Manager 是唯一注册的 App 接收者。共9次回复（3 PID control + 6 BID）全部匹配原 Manager 的 UUID/PID/role 和未开放能力状态。36次 Manager 注册快照均只见该 Manager，两个真实 Runner 进程仍存活并通过 RPC 心跳。
- 三个 Manager 普通终止，无 force terminate；六个 Runner 关闭自有继承通道后均自然 exit0。无显示/激活或 interactive-handler 拒绝事件。输入门禁、正式 G1/G5 继续关闭。

**关键限制：当前 Runner 命中原 hard gate，走 Foundation-only unavailable 服务，不初始化 GUI/WebView，且实测未注册为 App 接收者。没有验证“多个已注册 GUI Runner 与 Manager 竞争 Bundle ID 寻址”。不能把本轮结果说成完整多接收者路由已通过。**

分支 `mcc-safarier`，HEAD `2f32d21248deaffd8c8c1152a39912aa46350c7e`。两位 Terra worker 分别实现私有 driver 与 owned-runner harness；全部新 turn_context 核验为 `gpt-6.1-terra/high`。代码 review、独立构建/测试与真实执行由主 agent 完成，没有 reviewer 子代理。

## 1. 沿原 Runner 实现，不绕过门禁

- `Sources/Safarier/main.swift` → `ExecutableRole.run` → `RunnerMain.start`。参数仅 `run --profile <fresh UUID> --url about:blank --background-automation`。
- 新建本次 synthetic ephemeral profile，显式测试 opt-in；不修改已有用户 profile。继承真实 AF_UNIX stream socketpair 作为 stdin，沿原 ProfileLock、AutomationChannel、AutomationHandshake、AutomationRunnerServer。
- `RunnerPreparation.swift` 原 `shippingAdmissionAvailable=false` guard 直接进入 `AutomationRunnerBootstrap.serveUnavailable`，在 NSApplication、WebView、代理/准备副作用之前拒绝实际后端。
- 握手校验 profile/nonce/Runner PID/instance；capabilities RPC 严格要求 role runner、managerPID 等于真实父进程、backend unavailable、UI/cold unverified。nonce/rawframes 不写日志。
- 所有 receiver 启动数据位于既有内部私有 dataRoot，workspace/trace label 绑定、0700/no-symlink、独占 trace 保持。候选没有重建、重签名或迁移。
- 普通人工 Runner 会创建窗口；现有 `--probe` 同样创建屏幕外窗口并执行页面脚本，本轮都未使用。没有为 Runner 补 NSApplication、假 GUI 注册或运行时 Bundle ID。

私有实现根：`/Volumes/RC500/dev/safarier/.build/automation-runner-routing-20261102/`。仅测试工具，未加入产品依赖或新服务。

## 2. 身份、路由与清理边界

- driver 只接纳两个明确 PID，须同实际 Python 父进程、精确候选 EXE、健康运行/睡眠状态且未退出。发现身份仅作校验，不授权清理。
- Runner-only 仅观察。注册列表为空时先拒绝，不调用权限 API；已知非空列表才允许原有有界 false 预检。任何 capabilities 成功回复都视为“无 Manager 却意外成功”，不能冒充通过；UNAUTHORIZED 可记录无接收 PID 绑定的负例，非路由成功。
- Manager 用原 NSWorkspace exact URL/noop 标准启动，不 force-new；activates/prompts/recent/substitution 全 false。20秒成功和50秒未决边界不变。
- 只有原 callback-retained、新 launchDate/路径/BID 匹配且不属于 Runner 的 Manager 才授权清理。系统复用 Runner 或出现未知身份时拒绝，不终止发现的进程。
- 每次 Manager 预检/发送前后复核：仅允许明确两个 Runner 和 retained Manager 的注册集合，要求 Manager 存在；回复严格验证，BID 失败不回退 PID。
- 请求发送线程进入 C sender 前再次检查期限、两个 Runner 及 retained Manager 生命周期。权限函数与发送函数分离，预检晚返回不继续发送。
- Runner 清理由原持有 Popen+channel 决定：先关通道、有界 wait；异常/未证实清理停止后续周期。没有 PID 扫描清理、全局信号、SIGCONT 或 daemon 操作。

## 3. 主 review 修正与首轮真实失败

主 agent 退回修正了：runner-only 错把 capabilities success 当安全负例、发送线程遗漏即时生命周期检查、整帧超时不能因 partial trickle 无限延长，以及进程旗标语义错误。

SDK 的 `proc_bsdinfo.pbi_flags` 使用 `PROC_FLAG_INEXIT=0x4`；`0x200` 是资源节流，不能混用 kernel proc.p_flag 的 P_WEXIT。修正后仅 SRUN=2/SSLEEP=3 作为健康服务状态，SIDL/SSTOP/SZOMB 拒绝；不发送 SIGCONT。

### 首轮失败保留，不算成功周期

2026-11-02 18:18，真实 Runner PID11140/11141 握手/RPC均成功，注册列表0。旧验证工具仍对空目标执行 false 权限预检，5秒等待超时，driver exit1，Manager 步骤没有执行；两个 Runner 随后 EOF 自然 exit0。

Apple SDK 要求权限预检目标是已运行的可寻址应用。修复只收紧私有验证器前置条件：安全空注册快照直接 `no_registered_target`，`permissionChecked=false/sent=false/routingPassed=false`，不排队预检。没有延长超时、重新请求授权或把失败当 Manager 成功。

主 agent 独立重编译后，以 fresh labels 执行下面三个完整周期。旧失败目录、旧二进制、原日志及 reassessment 全保留。这不是盲目重试或产品 LaunchServices 修复。

## 4. 最终三轮真实结果

| 周期 | 真实 Runner PIDs | Manager PID | Manager callback | PID + BID 请求数 | Manager 后台样本 |
|---|---|---|---|---|---|
| 1 | 14161, 14162 | 14179 | 118.077 ms | 1 + 2 | 21 |
| 2 | 14187, 14188 | 14191 | 104.236 ms | 1 + 2 | 21 |
| 3 | 14238, 14239 | 14242 | 144.315 ms | 1 + 2 | 21 |

六次仅 Runner 观察均 registeredCount0、unknownCount0、身份有效、未预检/未发送。共存阶段36次快照均 registeredCount1、knownRegisteredRunnerCount0、unknownCount0、Manager 注册有效、两个 Runner 进程身份有效。

9次 Manager 回复的 requestID 全局互异，PID/role/gates 全匹配，OSStatus0；成功后能力仍 unavailable/unverified。六个不同 Runner profile/instance/PID 集合，六次握手与42次 capabilities RPC（含36次显式前后心跳）通过。关闭通道后全部自然 exit0，Manager 均原普通 terminate 并确认退出，无强制终止。

所有 Runner 构造标记 NSApp nil，未出现 DidFinish；原源码 hard gate 位于 GUI 构造前。所有 Manager 状态样本 inactive/accessory/0窗口/无key。所有目标无10…16显示激活保护命中，无31 interactive-handler 命中。

这三个 Manager 是**同一签名候选的新进程**，不冒充三个新签名首次启动。候选 SHA 继续 `a2e5bc0ec1bc4d38c48ec012bd231080c85e6b71cc32f0ee76fa3df9180e8237`；原 sender 身份修复源码 SHA 继续 `81bebcd1a01a9c0a063c60f82983129ff1769d92239e5bfdbec4127483fefe1e`。

目标过滤的 TCC 日志没有 AUTHREQ_PROMPTING，仍有6处 RemovableVolumes 静默检查记录，不能说系统不检查。没有 ask=true 或新 consent 请求。只读 observer 30秒3000样本、NSApp 全nil，cursor raw hash有两种；frontPID可能陈旧，光标变化也不能自动归因人工输入。本轮没有页面操作/持续打字/中文IME并发验收，G5不通过。

## 5. 独立离线验证与保留限制

主 agent 独立构建 driver/C shim、运行 sender stub/process/原 Swift/coexist Swift 四组纯测试，最终全部 exit0；独立运行 harness unittest 41项（含继承类重复案例），全部通过。AppKit七个显示/激活保护独立 SystemPreflight 通过、NSApp nil。RED/源码静态检查不冒充真实 API 证据。第一次 SHA 校验从错误 cwd 调用导致相对协议文件找不到的主操作失败原日志也保留，纠正执行目录后全清单通过，未改产品。

- 生产 Sources/Tests/scripts/Package、正常已安装 App、原 candidate 与 fence 未修改；相邻工作区和 index flags 保持。
- `shippingAdmissionAvailable=false`、`coldLaunchVerified=false`、默认 scripting candidate0 保持。无全局输入、System Events、页面 JS/输入、抢焦点/回位、VM、权限重置、缓存清理、helper 架构改造或安装/提交/发布。
- 本轮只证明当前 unavailable Runner 的安全负例和与 Manager 共存，不是正式 BID、实际 osascript、人工/前台 GUI Runner、旧副本或多注册接收者门禁。
- 路径/hash检查不是原子 fd-exec；App 注册前后快照不是任意并发情况下的原子路由保证。测试使用固定、复核不变的私有构建；不能据此开放生产输入。
- 下一步须单独设计人工 GUI Runner/正式身份的无干扰验证边界；若需要改为独立 Runner helper 身份，必须另行获批，不暗中增加服务或弱化身份。

## 6. 证据

根：`/Volumes/RC500/dev/safarier/.build/automation-runner-routing-20261102/`

- before.json、contract.md、worker-runtime-final.json、main-production-path-review.json
- driver/SHA256-SOURCES、各 RED/GREEN、HANDOFF.md；harness.py/test_harness.py/harness-HANDOFF.md
- main-build/verification-no-target-fix.log、main-harness-final-tests.log、main-fence-preflight.log
- main-code-review.json、main-reviewed-driver.json、sdk-process-flag-review.json
- first-failure-reassessment.json、main-runtime-summary.json 与旧失败 runtime 目录
- main-fixed-runtime-summary.json、main-routing-analysis.json 与三个 fixed runtime 目录（含原命令、stdout/stderr、回包校验元数据、receiver证据、逐周期独立检查）
- observation-fixed/readonly-evidence/、observer-fixed-summary.json
- target-tcc-runtime.log、tcc-summary.json、tcc-log-command.json、final-audit.json
