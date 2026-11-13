# Binder 身份校验与控制通道：无 GUI 离线实现设计

日期：2026-11-03；分支 mcc-safarier。状态：headless 离线组件已实现，并由主 agent 完成离线范围源码复核与独立复测；最终保全门禁以 `.build/automation-binder-identity-20261103/main-final-audit.json` 为准，不构成整体 Binder、真实 GUI、人工授权或输入放行。

## 1. 授权范围与已有实现

用户授权身份校验/控制通道的设计与离线实现，Terra 实现，主 agent 唯一 code review 与独立验证。允许自有、可回收的 headless CLI 子进程和匿名socketpair；不启动真实 Safarier/GUI，不触及 AppKit/WebKit、AppleEvent、权限/Keychain/LocalAuthentication API、osascript、全局输入、VM、安装/签名改写或监听服务。

保留产品与前轮 guard/candidate 不变。新组件仍位于 `.build/automation-binder-identity-20261103/` 隔离目录，本轮未接入正式 `Sources`、Manager 或 `RunnerMain`；真实 AppBundle 资源校验与 GUI Binder 尚未实现。本次直接编译复用现有 AutomationChannel、AutomationProtocol、AutomationHandshake（deadline helper）、OwnedRunnerProcess、RunnerLauncher（FoundationProcessSpawner）、RunnerLaunchSpec、SPIFeatures 七份原源码；不导入含 CredentialStore/LocalAuthentication 的整个Core模块，不新增另一套帧传输或进程执行器。

## 2. 真实 OS 证据与信任根

- 父侧必须保有原 FoundationProcessSpawner 返回的 OwnedRunnerProcess；observed PID 或 socket连通性不授予清理权。
- libproc 读取 PID/PPID、ruid/euid、birth sec/usec、健康状态和精确可执行路径；pbi_flags 使用 PROC_FLAG_INEXIT=4（不是kernel p_flag），拒绝调试/退出/特权变更标志；正常EXEC位不误拒绝。
- 继承的匿名AF_UNIX stream在对端使用后，采样LOCAL_PEERPID和严格32字节LOCAL_PEERTOKEN；核对audit PID/UID与所持有进程pin，再用原始内核token调用Security audit-guest lookup与动态有效性/code unique检查。
- 不用消息PID、同UID、nonce、fileSHA或静态copy代替动态校验；API不支持、token变化、code/路径/birth/UID不符或peer过早关闭均失败，不降级PID-guest。Self使用SecCodeCopySelf，不伪造audit token。
- 静态code unique pin和文件SHA256是两个独立字段。以O_NOFOLLOW和持有FD读取有界文件，记录完整dev/inode/size/nlink/UID/GID/mode/mtime/ctime，校验读前后和路径/祖先映射。资源只针对私有测试文件，不能称完整AppBundle资源认证。
- `/Volumes/RC500` 的775按当前严格策略被拒绝，不更改权限或放宽规则；可执行及资源固定在新建EUID拥有的0700 HOME私有run根中，源码与日志仍在项目目录，真实测试时不往已pin目录新增文件。receipt与制品摘要必须保留。

签名pin仅为精确制品一致性，不是开发者公信/公证或Hardened Runtime证明。LOCAL peer表示socket使用者/last-owner，不是逐消息不可伪造凭证；不宣称解决主动FD转交、同UID恶意调试/运行时篡改。文件/目录检查也不构成原子FD-exec或瞬态TOCTOU无竞态证明。真实GUI仍不得凭本层放行。真实认证事务的取消与并发对抗尚未覆盖，单元级取消或 gate 验证不能冒充该类集成验证。

## 3. Bootstrap 与双向控制

头less controller/endpoint使用同一冻结CLI映像。Endpoint从自身kernel路径/静态code pin及实际getppid确定父预期，不接受hello中的路径或hash作为信任根；controller从原owned child PID与kernel metadata确定子预期。没有UI放行环境变量；拒绝DYLD注入，子环境最小化。

初始peer last-owner可能是创建socketpair的parent。Bootstrap须显式未认证：endpoint先检查self及实际parent，再发固定有界presence；controller只接受其格式/时限，不赋权限，随后从真实内核peer确认child。未完成kernel核对不能继续hello。presence不是GUI-ready或业务成功。

之后按严格schema执行hello/proof/ack：sessionUUID、canonical nonce和握手requestUUID关联，双方seq独立单调递增。active阶段仅identity/ping/finish；endpoint identity-result/pong/finished必须匹配单个pending request UUID和kind；seen请求上限128，重放、未知键、重复JSON键、bool冒充整数、错误role/nonce/seq、晚结果或模糊写均poison关闭，不重试。

对已认证阶段的收发、接受前后重采self/peer/resource证据并对比初次pin；纯model的verified枚举不是运行模式认证来源。actor 的本地角色由可信启动上下文固定：保有原 owned child 的分支为 controller，基于实际 parent 的分支为 endpoint；发送只允许本地 role，接收只允许对端 role，不能由消息 body 或双方相同 CDHash 决定本地角色。actor 的状态、通道、身份对象与 `commit` 为 private，`commit` 仅在收发前后真实采集成功后调用；跨 `await` 的单事务 in-flight gate 明确拒绝重入并 poison/close，不能仅凭 actor 隔离推断不可重入。

ready/arm/manual-init/input/任意selector均拒绝，无app/window伪标记，不调用旧guard的manual_begin/seal/arm。`DENIED_NO_GUI_EVIDENCE` 是本地拒绝及 poison/EOF 的诊断，不是 wire 上结构化 error。传输身份确认只说明headless受控进程/通道，不是GUI准入。

`finished` 必须通过 peer 复核与状态机关联，模型进入 finished 后，parent 的 `finishAndDrain` 仅对自有 inspector 底层 stream 执行 `shutdown(SHUT_WR)` 发送 EOF，保持原 channel 读端及 parent 存活；endpoint 完成 `finished` 发送后身份复验、读取 parent EOF 并自然退出。parent 限时 drain 且只接受 EOF、观察原 retained owned child 精确退出 0，才完整关闭；任何额外帧、异常 half-close、超时或 ENOTCONN 均失败，不退化为宽松 peer 验证。这不是先完整关闭再宽松检查的路径。

失败清理先关闭自有 IPC，再有界等待；确需终止时只对仍运行、fresh kernel birth/path/UID 等与初次一致的原 retained owner 请求终止，再有界等待。证据不足或未观察到退出记录 `cleanup_unconfirmed`，不扫描 PID，不把未确认状态称作自然退出。

## 4. 时间、日志与清理

连接生命周期严格小于45秒，帧操作严格小于3秒。复用AutomationChannelDeadline，取消/超时关闭通道；昂贵OS调用返回后还须检查原期限，不接受迟到证据。

C collector采用CLOCK_MONOTONIC，Swift采用自身Dispatch uptime；不能拼接或直接比较两个epoch。Swift从本帧剩余时长调用bi_deadline_after_ms，再以Swift原期限做返回后检查。C检查不能中断阻塞OS调用，不把API返回时间当作必然有界。

记录own PID、阶段、结果布尔和制品摘要，不写raw audit token、nonce、原始帧或任意argv/env。正常结束按上述 half-close → EOF/drain → 原 owned child 自然退出 → 完整关闭；失败路径先关闭所有自有 FileHandle/inspector/CLOEXEC dup 再等待。异常、未决归属和未确认清理必须独立报告。

## 5. 证据与仍关闭的能力

源码与测试根：`.build/automation-binder-identity-20261103/identity/`、`control/`；主可行性probe在`main-probes/`，其早期peer先关闭及测试变量覆盖失败记录保留，持有至ACK的peer/audit/Security检查exit0。离线验证明细、worker 和主 agent 独立结果分列于 `docs/verification/2026-11-03-binder-identity-control-offline.md`。主 agent 另有独立 69 checks、六项真实通道负例及 manifest/依赖扫描，详见上述验证记录；其中预期负例退出 78 不代表一般成功，源码扫描的原注释命中及原始记录均保留。主 agent 已在新私有 root 独立复测同字节不同 inode 文件 rename 与 ancestor subtree rename：normal 和 ASan+UBSan 均在未变更时返回 `BI_OK`、变更时返回 `BI_CHANGED` 且输出哨兵不变；受控回调不证明原子 fd-exec 或瞬态 TOCTOU 不存在。主 agent 已复核本 headless 离线范围，最终保全门禁以 `.build/automation-binder-identity-20261103/main-final-audit.json` 为准。

分别证明纯parser/state负例、真实libproc/Security/文件证据和实际匿名channel/owned CLI往返，不能把模拟PID重用叫真实重用，也不能把测试resource叫真正Profile或AppBundle。

前轮GUI原型与本轮identity/control均未接入产品。GUI对象强持有/真实Profile与Bundle、人工授权、ready/armed、实际AppKit hook、Manager accessory、前台/Space和真实窗口清理仍缺证；完整P1、G1/G5、shipping/input/liveAdapter和真实GUI授权保持false。
