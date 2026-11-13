# 启动延迟归因：诊断数据位于可移动卷，触发 TCC 等待（2026-11-02）

## 结论

**本次被归为“LaunchServices启动延迟”的可复现等待来自验证探针启动前置文件I/O，不是已证实的产品Manager启动逻辑故障。** 私有诊断包在外接USB/APFS卷RC500创建prelude/trace/临时workspace；每次ad-hoc重签名改变代码要求，旧的可移动卷授权不再匹配，进程进入TCC授权提示流程。旧prelude记录直到该I/O返回才写出，不能据此推断进程尚未执行。

已沿原私有验证实现分离“固定候选程序位置”与“临时数据位置”，后者仅允许本机内部的本次私有目录。**三个不同签名新构建的首次启动全部通过原20秒门限，回调约171–234毫秒；没有预热、重试或提高门限。** 产品源码未改，既有UInt32身份修复、输入和发布门禁保持。

分支mcc-safarier，HEAD2f32d21248deaffd8c8c1152a39912aa46350c7e。两位Terra/high worker分别实现私有driver/fence，实际turn_context核验为gpt-6.1-terra/high；主agent唯一code review、独立测试及真实App执行。

## 1. 真实原因证据

外部数据控制：Tag101、叶节点替换、强制新实例、显式ascr/noop、无workspace观察器，保持旧App及Info inode不变。

- 2026-11-02 16:24:54.795：首个内部磁盘C标记出现，约在open调用后141毫秒；exe realpath耗时极小。
- 原preludeOpen整体直到16:24:56.600才完成，约1.805秒。
- 同PID36225的tccd在16:24:54.798记录`Failed to match existing code requirement`，服务为`kTCCServiceSystemPolicyRemovableVolumes`；54.799记录`AUTHREQ_PROMPTING`；56.593出现对应授权记录Create。

历史等待也对应同一机制：PID60540在13:43:38进入提示流程；PID67034在14:13:57进入提示流程，旧重试PID67191仍受影响；14:25:36授权记录Create后，自有PID68427的prelude随即完成，采样显示它已进入NSApplication.run。之前约30秒回调/无旧prelude的失败均保留，不能把它们说成LS始终未进入用户态。

**本轮外接卷控制也记录了系统授权提示请求。** 没有通过全局输入替用户点击或恢复焦点；没有直接观察提示的视觉细节，不能推断具体点击动作。识别后立即停止继续做外接卷的新签名启动控制，避免重复触发。未清除TCC记录、隔离属性、系统缓存或改签名要求。

只读TCC日志保存在本轮private evidence，不把其中身份/路径输出当作产品日志。自有receiver日志仅记录布尔值、类型/长度、阶段及自身PID，不记录事件正文或audit token原文。

## 2. 排除错误修复方向

- `openApplication`调用自身很快返回；新增driver阶段记录及最早内部磁盘C标记将等待拆开。
- 原打包脚本确实重建整个bundle，而历史探针只替换MachO；这是曾考虑的假设，**没有作为根因或实施依据**。最终三次仍使用同一旧App/Info inode、同Info字节和leaf更新方式，均启动成功，说明无需用bundle重建或LS缓存刷新掩盖问题。
- 原CLOCK_MONOTONIC与driver的mach uptime在本机约差4.5秒，主review发现后统一为mach_absolute_time/timebase，使用128位中间换算；没有用不同epoch计算虚假延迟。
- 新workspace观察器可能改变初始化，故最终三次均用quiet force/noop控制：不创建Observation、不注册workspace通知、不做进程快照，保留原实例/身份/就绪检查。

## 3. 最小修复与保留门禁

修复仅在本轮私有工具中：

`/Volumes/RC500/dev/safarier/.build/automation-launchservices-20261102/driver/`

`/Volumes/RC500/dev/safarier/.build/automation-launchservices-20261102/fence/`

候选EXE仍严格固定于旧EntryCandidate.app，诊断BID仍sh.safarier.g1probe。Receiver的SAFARIER_HOME、trace与prelude仅派生自：

`/private/tmp/codex-safarier-ls-20261102-dfbb7370e6/data`

该根及子目录0700、同EUID、无符号链接；独占600 trace、相同label绑定、精确EXE/BID和原身份检查保留。**不同时接纳旧外接数据前缀，不接受任意环境路径。** 没有迁移用户profile或修改生产默认目录；原生产默认本来是用户Application Support，SAFARIER_HOME只是本轮探针的显式覆盖。

七个AppKit显示/激活拒绝保护、45秒receiver watchdog、20秒成功截止和50秒无回调硬界限不变。观察对象不授权清理，只允许回调retained且身份匹配的对象被清理。ls-默认事件负例会在interactive原handler前退出73，保护普通桌面；本轮最终验收仍使用noop，不执行人类UI路径。

没有全局输入、System Events、VM、鼠标/焦点/IME回位，没有SIGCONT、daemon kill、Gatekeeper/TCC绕过、xattr清除或自定义弱签名要求。正常已安装App未动。

## 4. 独立回归与真正新签名首次启动

主agent独立重新编译driver、C进程元数据shim、fence，并执行原8组headless保护测试、LS阶段/时钟测试、driver纯测试及15项sidecar测试，全部通过。macOS Python缺失os xattr API的问题在review中被发现，改为只读Darwin fd接口，值仅保留SHA；未修改属性。

三个独立tag产生不同主二进制签名，每个仅在构建/签名后进行一次首次启动；无现存private实例，强制新实例及callback launchDate检查保留：

| tag / PID | 新签名主二进制SHA-256 | 首C标记 | 回调 | DidFinish | 原prelude I/O |
| --- | --- | --- | --- | --- | --- |
| 201 / 68189 | d73e361193d95d49ae06c5205746aa07f8f34cd86ffa8243272345cde6e34179 | 180.657 ms | 234.239 ms | 322.963 ms | 0.177 ms |
| 202 / 69552 | c23cb1c709792f038ef959b195fe01dddbc531b6bd46d9a8cc2f89f1a4fd1c4f | 126.950 ms | 170.751 ms | 201.364 ms | 0.189 ms |
| 203 / 71376 | a2e5bc0ec1bc4d38c48ec012bd231080c85e6b71cc32f0ee76fa3df9180e8237 | 161.966 ms | 200.373 ms | 317.000 ms | 0.148 ms |

时间均相对实际open调用前标记，DidFinish与callback为不同事件，不混算。driver固定2秒状态观察及正常退出耗时不是启动延迟。装配分别约0.30秒，没有把长等待移到装配、预注册或预热。

三次driver exit0，目标均inactive/accessory/0窗口/无key，无显示/激活保护命中，普通终止观察完成。原标记名称external_prelude_open为可比较的旧名称，修复后的实际路径已是内部目录。

系统日志17:02之后未出现匹配本诊断身份的AUTHREQ_PROMPTING；仍有少量静默RemovableVolumes检查/旧代码要求不匹配信息，**不能称TCC不再检查，也不把签名验证的platform-app否定当作新故障。** 关键是没有再进入提示等待。另一次真实只读capabilities请求以false预检0通过，回复requestID/PID/角色及未开放能力状态严格validated、driver exit0；UInt32 auth修复保持。

## 5. 明确保留限制

- 解决的是此次私有验证链路的延迟来源；没有臆改Manager生产启动流程，也不声称修好了系统LaunchServices内部机制。
- 正式BID、仅Runner存活/多Runner唯一接收、人类UI冷/热/reopen以及页面输入/中文IME仍未完成，**完整G1及正式输入门禁继续关闭**。
- 真实用户若显式使用外接卷profile，仍须遵守系统授权；本修复不授予或绕过外接卷权限。后续自动化测试不得在新签名GUI进程启动前置路径创建外接卷数据，更不能让新签名卷授权提示影响用户操作。
- 未运行会置前窗口的完整UI XCTest，不宣称旧344项本轮重跑。只读observer frontPID可能陈旧，不用常量值证明焦点；cursor确有变化，本轮不是页面自动操作与持续打字/中文IME的G5验收。
- 生产源码及之前Auth修复SHA81bebcd1...249fefe1e未改，正常App、相邻工作区及旧10个缺失assets/skip-worktree保持。无安装、commit、push或发布。

## 6. 证据

根：`/Volumes/RC500/dev/safarier/.build/automation-launchservices-20261102/`

- before.json、contract.md、bundle-before-metadata.json
- prior-tcc-private-log.log、historic-tcc-delay-log.log、postfix-tcc-private-log.log
- main-headless-validation.log、main-internal-fence-validation.log、main-fixed-driver-sidecar-validation.log
- internal201/202/203-summary.json、fresh-first-launch-summary.json
- assemble-*及trial-ls-internal*-*的独占运行目录，含metadata/xattr SHA、原命令/状态、receiver及observer副本
- postfix-capabilities.log、main-verification-summary.json、final-audit.json
- internal-receiver-evidence/为本次内部临时证据的保存副本；内部临时路径不是安装或发布布局。
