# Safarier 本地候选静态角色包设计

日期：2026-11-05  
状态：用户已确认该方案；本文仅定义实现合同，不代表构建、权限、运行或发布已经通过。代码 review 仅主 Agent 执行。

## 1. 目标与既有路径

保持一个外层 `Safarier.app`，复用原 Runner 进程实现、`NativePageInput`、socket-v1、owned Process、ProfileLock loan、Binder channel 和既有 Manager／AppleScript 链；仅把候选 Runner 的启动身份固定为外层内嵌的独立签名 app。Manager 仍是其控制 BID 的唯一接收端；不通过 PID、注册顺序或 role label 选择 Apple Event 接收者。

实测原 Manager 与 owned Runner 同 BID 登记；本进程 LaunchServices SPI 加两秒观察仍为两个注册项，该试验源码已撤回。不是更改 `count == 1`、runtime BID、进程角色或操作系统状态的理由。基线为本地 `mcc-safarier`、HEAD `2f32d21248deaffd8c8c1152a39912aa46350c7e` 的共享 dirty workspace；96 个 build 输入与先前实际 owned-proof App 的源码收据一致。本方案的精确授权与写入范围以 `.build/automation-bound-control-integration-20261104/static-role-20261105/contract.json` 为准。

实施前源码基线约束：`RunnerLauncher.currentExecutableURL()` 默认当前可执行文件，`AutomationRunnerClient.start` 和 `KernelIdentityBridge` 目前将 self 与 peer 限为同一路径／同一 pin；`BundleResourcePin` 目前只有单一 `OfflineBundleContract.localCandidate`；`RunnerBinderContext` 从 Runner executable 推导 fixture；`Sources/Safarier/main.swift` 原按参数选择角色。必须沿这些真实路径做静态角色化，不能在外面再叠一套认证或第二 transport。非 candidate 的手动／交互路径保持原状。

## 2. 静态包与不可变精确 namespace

下表的每一行均计作一个目录或文件；不允许 symlink、额外资源、未知文件。Runner 的 8 条和 Main 的完整 19 条必须分别验证，Main 的清单包括整个嵌套 Runner：

| 相对 Main 的路径 | 类型 |
| --- | --- |
| `Contents` | 目录 |
| `Contents/Info.plist` | 文件 |
| `Contents/MacOS` | 目录 |
| `Contents/MacOS/Safarier` | 文件，Main executable |
| `Contents/Resources` | 目录 |
| `Contents/Resources/Safarier.sdef` | 文件，仅 Main |
| `Contents/Resources/control-fixture.html` | 文件 |
| `Contents/_CodeSignature` | 目录 |
| `Contents/_CodeSignature/CodeResources` | 文件 |
| `Contents/Helpers` | 目录 |
| `Contents/Helpers/SafarierRunner.app` | 目录，Runner 根 |
| `Contents/Helpers/SafarierRunner.app/Contents` | 目录 |
| `Contents/Helpers/SafarierRunner.app/Contents/Info.plist` | 文件 |
| `Contents/Helpers/SafarierRunner.app/Contents/MacOS` | 目录 |
| `Contents/Helpers/SafarierRunner.app/Contents/MacOS/SafarierRunner` | 文件，Runner executable |
| `Contents/Helpers/SafarierRunner.app/Contents/Resources` | 目录 |
| `Contents/Helpers/SafarierRunner.app/Contents/Resources/control-fixture.html` | 文件 |
| `Contents/Helpers/SafarierRunner.app/Contents/_CodeSignature` | 目录 |
| `Contents/Helpers/SafarierRunner.app/Contents/_CodeSignature/CodeResources` | 文件 |

- Main：BID `sh.safarier.boundcandidate`，leaf `Safarier`，继续具有 `NSAppleScriptEnabled`、`OSAScriptingDefinition=Safarier.sdef` 和原 `SFRAutomationRequestCommand`。
- Runner：BID `sh.safarier.boundcandidate.runner`，leaf `SafarierRunner`；无 sdef、AppleScript 控制声明、URL／文档注册或额外 bundle 资源。它是现有 Runner 的静态打包身份，不是 broker、service、输入 helper 或独立安装产品。
- Main 与 Runner 各自 fixture SHA-256 固定 `45f599bd8d943192d3f93045559a825b8922f5b2df8106393fc896394355edc1`；Main sdef SHA-256 固定 `0cb1c89e68376982342c0a4821b8f9a719d99e4ceb5b476e5ec748e773b5890c`。父子 plist、executable、CodeResources 的实际 SHA 和签名身份在打包完成后分别生成、由主 Agent 独立固定，不自我嵌入文件 hash。
- 从新独占 scratch 的原 `swift build --product Safarier` executable 复制两份；先组装并签 Runner，再放入 Main 并签 Main；分别 `codesign --verify --strict`，检查父 19／子 8 精确路径和两份 fixture。任何输出已存在、构建中源码变化、签名／namespace／固定 hash 不符均停止；不覆盖、不删除旧产物。若真实编译产物要求超出该 namespace 的资源，停止报告，不悄悄加资源。

## 3. Core 角色对与身份接口

以下是**语义接口**，不是可由不可信调用者直接构造的公共授权 API；由 Core 实现者在现有实现中选择最小类型／签名，先与工具／App 入口对齐：

1. `staticRolePair`：从实际 self 的 C 元数据和 code evidence 确定 self 属于固定 Main 或 Runner 路径，再在同一已验证外层结构中确定唯一 opposite role。只允许两个固定 BID、leaf、相对位置和对应完整 namespace；参数、环境、role label、bundle 标识或 target 自述 manifest 都不是身份授权。候选标记只选择待验证路径，不能授予权限。
2. `selfPin` / `oppositePin`：以现有 `bi_static_pin`、`bi_capture_self`、`bi_capture_peer`、`bi_match`／evidence 比较及 `bb_inventory`、`bb_expect_exact`、`bb_revalidate` 等真实 C API 为基础，分开 pin 两个角色的 executable、签名／Info 和资源；不得以共同 TeamID 或 BID 代替精确代码证据。Runner 检查实际 parent，Manager 检查原 retained owned child 的 birth／ppid／uid／path，socket peer 再与该原始证据相等。未知、替换、重签或不一致均 fail closed。
3. `parentInventory` / `runnerInventory`：建立和重验包含 Runner 全部内容的 Main 完整稳定清单，同时初始严格校验 Runner 自身身份与精确 8 项；每次原身份／页面／写入提交前的真实 C 校验需覆盖完整父清单和已固定的子身份。不能只检查某个可被替换的 leaf，也不能从候选包内可变 manifest 获取权威。
4. `verifiedRunnerExecutable`：仅从已验证的静态角色对派生固定 Runner 路径，交给现有 `RunnerLauncher`／`OwnedRunnerProcess`；不能把 argv、环境变量、PID 文件、扫描或外部路径作为 authority。Runner 的 fixture 仍从经验证的 Runner bundle 固定 Resources 路径取得。同一实例、原 held lock／loan、reader、writeQueue、Pending、frame／lifetime 预算与 cleanup 保持原语义。

自／peer 的完整独立 code pin 由封闭上下文保管并在真实 C 校验处使用；build 收据可供主 Agent 在启动前独立 pin，但收据不能作为 runtime 从目标读取的信任根。若现有 C API 无法同时表达上述校验，停止并向主 Agent 报告，不能弱化检查或擅自修改 C／headers。

## 4. 入口、控制和安全边界

`main.swift` 只把受静态角色对约束的 Runner 包引入原 Runner 入口；角色路径／参数可作分流线索，最终授权仍来自 Core 实际 C 自／父／子／peer 及完整 inventory，helper 不得借角色字符串进入 Manager。不得 runtime 改 BID、plist、进程身份、TCC、LaunchServices、daemon 或 WindowServer；不新增旁路产品 CLI。候选非自动化及原非 candidate 手动路径不因本改动转成后台运行。

GUI 仍以同一个实际 sender 的 false-preflight 和 OSA `automation request` 执行；每次发送使用原 noPrompt／neverInteract、目标检查及事件白名单。需要 consent 时停止，不调用 ask=true，除非用户另行批准。每次 UI/native 动作之前原实际 C self／opposite、资源、birth／peer、context、lease、目标／活动检查必须仍有效；不因 `ready`、BID、路径、环境、静态角色、role label 或测试 flag 跳过。外层 same-BID `count == 1` 不变。

`shippingAdmissionAvailable=false`、`coldLaunchVerified=false` 和普通未验证输入的 shipping gate 保持 false；仅固定 fixture 的既有候选局部能力可用于本次 pointer／query／close 验证，不扩大到任意 URL、键盘、密码、滚轮或系统级输入。不得把候选结果写成完整 G1/G5 或已证明不干扰用户键鼠。异常、超时／身份无法证明时保守关闭，保留 lock loan／drain 语义；只可依据原 retained Process 和 fresh birth 做有界处置，不能扫描、以 PID 文件或登记列表杀进程，也不恢复焦点或光标。

## 5. 验证与停止条件

主 Agent 唯一执行代码／设计 review 和最终放行。Core 与 tools/App 各自只在合同写集工作，保留并适配他人改动；两方接口先对齐再集成。一次 normal candidate build 后做少量隔离复制品的静态签名／角色负例，然后只有主 Agent 对源、父子 code/resource pin、root、namespace、strict signature 和 sender 独立固定并明确派发，才做一次真实 GUI。所有阶段使用新 stage／attempt／root，保存 source SHA、argv、受限 env、stdout/stderr、exit；绝不改旧 App、旧用户资料或旧证据。

真实 GUI 必须区分：实际启动／注册与 retained owner、权限 preflight、capabilities/open/getState、hover／截图／drag 回执、fixture 可见证据和 cleanup。缺任一证明就记 unknown／失败；无授权或权限未确定立即停。无 full swift test、ASan、release、lipo、VM、大矩阵、安装、自动重试或未经请求的 commit/push。

## 6. 2026-11-05 静态角色实测状态（不改变上述门禁）

经主 Agent 复核，Core 角色对与工具／App 入口已完成；Terra worker 执行的一次 normal candidate build 的 97 项源码前后相同，host 离线编译的 8 项源码前后相同。主 Agent 独立核对 Main 19／Runner 8 namespace、两端独立 identifier／code pin 与 strict/deep signature。实际 C 定向负例四项按预期拒绝：Main 错 BID、Runner 错 leaf、固定父 pin 后修改 Runner fixture、父 19 项清单增加额外项；helper Info 篡改与重签未覆盖，不能宣称静态负例全面通过。

一次实际 GUI 中，Manager 快照 `matchingCount=1`、`managerRegistered=true`、`originalOwnedRunnerRegistered=false`、`sameEndpointOwnership=true`、`realCoreRoundtripValidated=true`、`otherRegistrationsCount=0`；capabilities、openSession 和 getState 有成功回执，说明原同 BID 唯一路由阻塞在本次运行被跨过。首个 hover move 返回 `INDETERMINATE_RESULT`，可能存在或不存在副作用，原因未知；截图、drag 和 closeSession 未执行，没有 `hover.png`。总 smoke 退出 1，Manager 的原 retained Process 退出 status 15 已观察，Runner 独立退出／清理观察未知。不得将本次结果表述为完整 GUI、shipping、G1/G5 或不干扰用户键鼠通过。

证据：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/static-role-20261105/main-artifact-review-001/result.json`；实际 C 负例 `/Users/yingzhang/safarier-static-role-negative-20261105-52455065c29140b399c9a8953d4d53ba/summary.json`；GUI 外层 `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/static-role-20261105/worker-tools/gui-001/runtime-001/`。本记录不授权下一次 GUI、重复 hover 或改变任何预算／门禁。

## 历史：当时后续实际状态（2026-11-05）

静态角色原唯一路由阻塞已跨过；两次新 session 的真实 hover ACK、绿色截图和 drag 回执已有证据，但 closeSession 门禁仍失败、整体 GUI 未通过。早期 `INDETERMINATE_RESULT` 为历史结果，不可追溯替换。详见 `/Volumes/RC500/dev/safarier/docs/verification/2026-11-05-hover-native-ack.md`；不代表完整 G1／G5、shipping 或人工并发键鼠长期验收。

## 最新固定 fixture 状态（2026-11-05）

原静态角色身份和接收端门禁保持，raw-cutoff 候选在两个新 session 完成原真实 fixture 小链与 page／store close proof，均 smoke exit 0。范围与证据见 `/Volumes/RC500/dev/safarier/docs/verification/2026-11-05-close-session-proof.md`。Task 3 的 helper Info／重签负例仍未覆盖；不宣称任意 URL／键盘、人工并发键鼠长期、完整 G1／G5 或 shipping 通过。
