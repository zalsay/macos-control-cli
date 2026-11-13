# 单一私有 Manager 的 Bundle ID 路由验证（2026-11-02）

## 结论与范围

沿用已修复启动数据位置的私有诊断包，新增只读 Bundle ID 寻址验证。三个新进程均以 `createsNewApplicationInstance=false`、显式 `ascr/noop` 启动；每轮先做一次 PID control，再做两次真正 `typeApplicationBundleID` 寻址的 capabilities 请求。三轮共9次回复全部严格验证 requestID、Manager PID、role 和尚未开放的能力状态，正常终止并观察退出。

**仅证明固定诊断 BID `sh.safarier.g1probe` 在单接收者条件下的路由；不是正式 BID、多 Runner 或实际 osascript 解释器验收。完整 G1 与所有页面输入门禁仍关闭。**

- 分支 `mcc-safarier`，HEAD `2f32d21248deaffd8c8c1152a39912aa46350c7e`。
- 实现由 Terra worker 完成，fresh turn_context 核验 `gpt-6.1-terra/high`；代码 review、独立编译、真实 App 和 Apple Event 均由主 agent 执行。
- 没有新增产品功能/第二套服务；本轮只扩展原私有验证 driver。没有重建或重签 receiver。

## 1. 沿原实现扩展

工具源码在 `/Volumes/RC500/dev/safarier/.build/automation-bid-routing-20261102/driver/`。

- Sender 沿原 PID sender 的编码、回包、错误处理流程提取共用函数，新增仅固定 BID 的 `bund` UTF-8 descriptor。BID 请求失败不回退 PID；PID control 是显式独立验证。
- 保留原精确 EXE/BID/同 UID/launchDate 检查、callback-retained owner 清理、20秒成功限与50秒未决限。发现到的进程只校验，不授权终止。
- 参数模式 `bid-standard-capabilities` 仅接纳 `ls-bid-` label。quiet 模式不创建 Observation；不注册额外 workspace 通知或采集进程快照。
- launch 配置 activates/promptsUserIfNeeded/addsToRecentItems/allowsRunningApplicationSubstitution 全为 false；createsNewApplicationInstance=false、显式 noop。
- BID 预检和发送前后检查原 retained App 身份及同 BID 唯一存活实例。每个请求 fresh UUID，所有回复均要求 managerPID/role 匹配、backend unavailable、uiPolicy/coldLaunch unverified。
- 预检仅 askUserIfNeeded=false；发送保留 waitReply/neverInteract/dontRecord/doNotPromptForUserConsent。任何预检/身份/回复失败即停止该轮后续请求并走原 owner 清理。

### 主 review 发现并修正的期限风险

初稿在 C 的 BID send 内再次做权限预检，存在预检迟到返回后越过外层期限继续发事件的风险。主 agent 退回后，Terra 改为独立 `g1_permission_bid`：Swift 有界等待，预检后检查绝对期限、owner/唯一性，再进入带 dispatch deadline 的原发送任务。send 本身不重复预检；晚返回不触发发送。权限函数不发送、发送函数不预检由 stub 测试验证。

唯一性检查是请求前后快照，不是任意并发启动场景中的原子路由保证；不能据此放行多实例门禁。

## 2. 独立验证

主 agent 将 C sender/process shim、Swift driver/tests 编译到独立 `main-build/`；核对冻结源码 SHA，独立运行 sender stub、process、Swift 离线测试，全部 exit0。负例覆盖错误 UUID/PID/role/gate、无效编码、非唯一 owner、权限拒绝、deadline 边界和 sender 错误传播。

C sender 测试的所有 AE create/put/get/dispose/send/permission 调用均为 stub，不发送真实事件。实现前 red 日志与冻结 SHA 保留；新增接口部分 red 为实现前编译缺失，不能说成所有场景都有行为级 red。

另独立编译并运行原 SystemPreflight：七个 AppKit 窗口/激活保护 ABI/来源检查通过，NSApp 仍 nil。第一次纯测试编译因生产 constructor 排除后的两个 unused static helper 在 -Werror 下失败，原日志保留；仅测试构建加 -Wno-unused-function 后通过，未改 fence 源码或 receiver。

## 3. 真实结果

| 轮次 | Manager PID | 启动回调 | PID + BID 请求数 | 后台状态样本 | driver exit |
|---|---|---|---|---|---|
| 1 | 88256 | 210.890 ms | 1 + 2 | 15 | 0 |
| 2 | 88266 | 104.788 ms | 1 + 2 | 15 | 0 |
| 3 | 88286 | 208.524 ms | 1 + 2 | 15 | 0 |

每轮回调准时、DidFinish/ready、owner 清理均通过；9个请求 UUID 互不相同，permission 状态全0、回复 OSStatus 全0。三次均无10…16显示/激活拒绝事件，也无31 interactive-handler preemption。全部45个 App 状态样本 inactive/accessory/0窗口/无key。原护栏仍在，未走人类 UI 路径。

这是**同一签名的三次新进程启动**，不是三个新签名首次启动；新签名首次启动证据仍见上一份启动延迟报告。本轮不预热、不提高门限。

候选二进制 SHA 保持 `a2e5bc0ec1bc4d38c48ec012bd231080c85e6b71cc32f0ee76fa3df9180e8237`；身份修复源码 SHA 保持 `81bebcd1a01a9c0a063c60f82983129ff1769d92239e5bfdbec4127483fefe1e`。Receiver 启动数据继续只在既有 `/private/tmp/codex-safarier-ls-20261102-dfbb7370e6/data`，未恢复外接卷数据前缀。

本轮目标过滤系统日志没有 AUTHREQ_PROMPTING；仍有6处 RemovableVolumes 静默检查相关记录，不能称系统完全不检查。所有 API 调用均无 ask=true。只读 cursor observer 覆盖三轮 open 前至清理后，30秒3000样本、NSApp 全nil、cursor raw hash 为一种。observer 的 frontPID 可能陈旧，不能作焦点证明；没有人工持续打字/中文 IME 或页面动作并发验收，不能称 G5 通过。

## 4. 保持关闭与下一步

- 未改生产 Sources/Tests/scripts；未触碰正常 `/Applications/Safarier.app`，未安装、提交、推送或发布。
- 没有全局输入、System Events、页面输入、鼠标/焦点/IME 回位、VM、TCC重置或系统缓存修改。所有诊断 App 已退出。
- `NativeInputPreflight.shippingAdmissionAvailable=false`、`coldLaunchVerified=false`、默认 scripting candidate0 保持。
- 剩余重点是仅 Runner 存活、Manager+多 Runner、旧副本/正式身份下唯一接收者及人工生命周期。不得把本轮单私有 Manager 结果外推到这些场景。
- 正式 BID 检查可能涉及已安装 App 的注册/授权/人工窗口，不能为追进度自动执行；先制定隔离验证边界。若必须改变 Runner helper 身份架构，另行解释并取得批准，不暗加 helper 或服务。

## 5. 证据

根：`/Volumes/RC500/dev/safarier/.build/automation-bid-routing-20261102/`

- before.json、contract.md、worker-runtime-final.json、sdk-reference.json
- driver/SHA256-SOURCES、red/deadline/permission/sender-red 等日志及冻结实现
- main-code-review.json、main-reviewed-tool.patch、main-build/verification.log
- main-fence-preflight.log（失败保留）、main-fence-preflight-rerun.log
- runtime-summary.json、runtime/各轮命令/原stdout/stderr/退出状态/receiver trace与prelude/原始阶段副本
- observer-summary.json、runtime/readonly-observer-evidence/
- tcc-target-runtime.log、tcc-log-command.json、tcc-summary.json
- final-audit.json
