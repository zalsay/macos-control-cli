# Manager 打包入口与无提示 TCC 预检（2026-10-30）

## 结论

**G1 仍未通过，不开放输入、正式 AppleScript 入口或发布门禁。** 本轮取得真实 Manager 启动事件的重复证据；首次 LaunchServices 启动仍有未定位的失败，能力命令则停在需要用户同意的系统授权预检。不能把重试成功写成首次启动问题已修复。

- 工作分支 `mcc-safarier`，HEAD `2f32d21248deaffd8c8c1152a39912aa46350c7e`。
- Terra/high worker 实现私有验证工具，主 agent 唯一 code review，并独立编译、测试、打包、执行和复核日志。两位 worker 的实际 turn_context 模型为 `gpt-6.1-terra`、effort `high`。
- 改动前 287 个已有仓库文件哈希全部保持；本轮生产 Sources、Package、原测试/夹具没有改动。收尾仅新增本报告和追加计划记录。没有安装、提交、push 或发布。

## 范围与保护

使用当前源码的 SwiftPM **debug** 可执行文件，组装单独的诊断 App；不是本轮完整 release 打包验收。候选路径：

`/Volumes/RC500/dev/safarier/.build/automation-manager-entry-20261030/packages/EntryCandidate.app`

诊断 Bundle ID 为 **`sh.safarier.g1probe`**，不是已安装 App 的 `sh.safarier.app`。只在私人目录启用 scripting candidate 元数据，LSUIElement=true；ad-hoc 签名及 deep/strict 校验通过。正式默认 scripting candidate=0、Native shipping admission=false、Manager coldLaunchVerified=false 和 background Factory 拒绝均未改变。

- 私有 constructor 在 Swift main/NSApp 前验证固定可执行路径、诊断身份、700 workspace、独占600 trace；环境或身份不符即停止，不使用正常用户 profile。
- 本进程七个 public AppKit 激活/窗口入口做完整方法归属、ABI、原 IMP 映像/符号校验；regular policy、activate 和显示/置 key 调用在原方法执行前退出71。45秒独立 watchdog 只约束已进入 constructor 的进程，不能假称覆盖尚未执行 constructor 的启动停滞。
- 只包装原 Manager 已有的 automation/interactive handler，原参数精确转发一次；没有另注册 Apple Event 接收器、增加服务或改写产品生命周期。
- 驱动使用 NSWorkspace activates=false、新实例且禁止替代；最新版本还明确关闭 promptsUserIfNeeded 和 Recent Items。SDK 明确 Gatekeeper UI 不受前述 prompts 开关影响，本轮没有绕过系统安全机制。
- 仅保留并核验本次返回的 NSRunningApplication 后清理该对象，不按 Bundle ID 查找并结束用户进程。没有 CGEvent 全局输入、System Events、鼠标移动/回位、焦点或 IME 恢复。

## 实际失败与归因边界

| 记录 | 实际结果 | 限制 |
| --- | --- | --- |
| cold-1，初始候选 | 约30秒才返回 owned 对象，未见 receiver trace；普通终止后需 forceTerminate | 失败保留，首个外部 observer 仅15秒，未覆盖全过程 |
| direct-stack-1 | 同初始二进制直接启动约0.14秒进入正常 NSApplication.run；private trace 显示 inactive/accessory/0窗口 | 直接启动不等于 LaunchServices 冷启动 |
| cold-sync-1 / async-control-1 | 同初始候选，两种驱动均及时启动、正常终止 | async 对照为源码哈希一致的重编译件，不是原 cold-1 binary；不能归因于 RunLoop 修复 |
| direct-stack-2 / direct-metadata-1 | 新 handler 诊断保护层先退出70 | 实际 Class 名为 Safarier.ManagerAppDelegate，原诊断器错误要求 mangled 名；两方法 own/完整ABI/映像均正确 |
| cold-event-1 | 无 receiver trace，约23秒返回 PID=-1，身份拒绝，不清理不明对象 | 不能推断是产品执行器问题 |
| cold-final-1，最终候选 | 30秒返回 owned PID6572、未 finishedLaunching，无 C prelude/receiver trace；本次最终观察清理完成，需 forceTerminate | 两个重叠30秒 observer 覆盖全过程；尚未定位早期停滞，不能认定具体系统原因 |
| cold-owned-stack-1 | 未复现停滞，及时启动并正常结束 | 因不满足 late 条件，正确地没有调用 sample；**没有取得失败现场栈** |

修正仅限私有诊断器对实际 demangled Class 名的精确识别；仍检查固定模块/两个查找结果一致、own method、完整 ABI 和候选映像。没有放松产品门禁。没有将上述早期停滞认定为已修复、必然是缓存或必然是 LaunchServices bug。

## 最终候选的三轮进程重新启动

最终候选主二进制 SHA-256：

`24284a9b3e279ef44e584d4fa57c45a7558aadb9dc0d2781fc59fe16c23c35f8`

每轮开始前无该诊断 App 在运行，均使用相同最终候选；**不是三个全新构建/首次安装的冷启动**，不能抵消 cold-final-1 的失败。

| 标签 | PID | fence首条记录至DidFinish | 实际接收与状态 | 收尾 |
| --- | --- | --- | --- | --- |
| cold-owned-stack-1 | 10681 | 116.066 ms | 原 handler 收到 ascr/noop，先于DidFinish；inactive/accessory/0窗口/无key | 请求普通终止并观察退出 |
| cold-repeat-2 | 13189 | 167.112 ms | 同上 | 同上 |
| cold-repeat-3 | 13206 | 64.037 ms | 同上 | 同上 |

三轮没有 interactive handler 事件，没有激活/置 key/显示 tripwire 命中。这里的毫秒数是 receiver trace 两条记录间的时间，**不是完整 LaunchServices 冷启动耗时**。NSRunningApplication 不提供目标退出码，driver exit0 不冒充目标 App exit0。

## 能力查询的授权边界

`capabilities-1` 的 Manager PID13225 同样及时启动、实际收到 noop 且保持 inactive/accessory/0窗口/无key；随后按 retained PID 执行：

`AEDeterminePermissionToAutomateTarget(..., SFAu, requ, askUserIfNeeded=false)`

实际返回 **-1744**。本机 SDK AppleEvents.h 将其定义为 `errAEEventWouldRequireUserConsent`。驱动按既有控制流立即拒绝后续发送，正常终止并观察到目标退出。

**未触发授权框，未调用自定义命令的 AESendMessage，未获得 capabilities 回复。** 已实现的发送/回复校验代码仍只获离线测试，不是实机接通证据；更不是 AppleScript 语言调用、OS sender 属性、异步 suspend/resume 或唯一 Manager 路由验收。后续若需真实查询，要先单独取得用户同意触发系统授权；不能通过代理发送者、假身份或放松验证绕过。

## 外部观测与验证限制

最终三轮及能力预检均有独立只读 observer 覆盖；cold-owned-stack-1 单独3000样本，final batch另3000样本覆盖其全部三个 driver 生命周期。observer 始终 NSApp=nil。

- 实际存在外部活动及 cursor hash 变化，不能宣称全程鼠标未动/光标形状恒定。final batch 在 HID/combined 两个计数域分别观察到 keyDown/up各14、leftDown/up各6、leftDragged2、mouseMoved423；域名称不保证硬件来源，整段计数也不等于每个目标存活区间都有键盘活动。
- **独立 observer 未泵主 RunLoop，其 NSWorkspace/NSRunningApplication 动态 frontPID 可能滞后**；实际与驱动已出现不同读值，不能用它的常量 frontPID 作为持续焦点未切换的证明。主要正面证据为候选自身实际 isActive/policy/window/key 状态、无危险调用命中，以及接收事件顺序；不是对全桌面无干扰的穷尽证明。
- 本轮没有任何页面输入，不能用键鼠活动计数冒充页面自动操作时持续打字/中文 IME 验收；G5 仍未通过。
- 主 agent 独立编译运行 Prelude、Metadata、ManagerIdentity、Handler、Workspace、Fence dummy、实际 AppKit system preflight 及 driver 纯测试，全部通过；实际七方法预检维持 NSApp=nil。最新 app debug build exit0。**本轮没有重新跑原344项 XCTest或9x25页面矩阵**，上轮结果仍只属于上轮。

## 文件与下一步

证据根目录：`/Volumes/RC500/dev/safarier/.build/automation-manager-entry-20261030/`

重点文件：

- `before.json`、`installed-app-before.json`、`candidate-build-review.json`
- `main-final-entry-tests.log`、`main-frozen-driver-tests.log`、`final-fenced-app-build.log`
- `cold-final-1-status.json`、`cold-final-1-driver.log`
- `cold-owned-stack-1-status.json`、`final-batch-status.json`
- `traces/`、`prelude/`、`main-verification-summary.json`、`final-audit.json`

收尾验证已安装 `/Applications/Safarier.app` 的 Info.plist/主二进制哈希不变，未启动它；无诊断 App 残留；相邻 chrome-control-cli 工作区状态、原缺失10个 assets 与 skip-worktree 标记不变。

下一步分别处理：首次构建 LaunchServices 早期停滞的可复现现场；用户授权后的真实只读能力回复；正式 Bundle ID/仅Runner存活/Manager+多Runner的唯一接收；安全 Factory/Runner/页面输入/销毁回执；真实并行键盘与中文 IME。所有正式门禁继续保持关闭，不用全局输入兜底。
