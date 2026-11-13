# 一次性系统授权与真实只读命令（2026-11-02）

## 本轮结论

用户明确允许一次 macOS 自动化授权，仅用于只读 capabilities 查询。

**系统授权请求返回0，真实 Apple Event 发送/回复的 OSStatus=0；但应用回复为 UNAUTHORIZED。能力查询失败，driver exit1，不开放任何输入或发布门禁。** 这是从“系统预检阻止发送”推进到了“已获得真实接收端拒绝回复”，不是能力闭环成功。

## 范围与实现

- 仓库 `/Volumes/RC500/dev/safarier`，分支 mcc-safarier，HEAD 2f32d21248deaffd8c8c1152a39912aa46350c7e。
- 新私有工具仅位于 `/Volumes/RC500/dev/safarier/.build/automation-consent-entry-20261102/driver/`。复用上轮驱动和同一未重签名候选，不增加执行器、服务或产品接口。
- 新 worker 的实际 turn_context 为 gpt-6.1-terra/high（01a19aad-4110-7992-ab0d-4da64ddc0ce1）；主 agent 唯一执行 code review 和实机验证。恢复旧 worker 时检测到模型漂移，已在其写文件前停止；最终实现来自新 Terra worker。
- 默认模式继续只调用 askUserIfNeeded=false。显式 capabilities-consent-once 仅在预检-1744、核验本次 retained owner、启动预算足够时，独占创建600权限的持久 consent.once，再安排至多一次 askUserIfNeeded=true。
- 请求在后台线程执行、最长等待20秒；启动预算保守从发起LaunchServices前算，进入请求必须不超过5秒。迟到/拒绝/身份丢失均停止，无权限重置、重试或代理发送。既有45秒 receiver watchdog 不变。
- 授权成功后仍只允许一条既有SFAu/requ capabilities 请求；保留never-interact/do-not-prompt发送标志和严格回复ID/PID/能力校验。没有打开profile、Runner、页面或执行任何鼠标键盘动作。

## 主 agent 独立离线验证

主 agent 复核源代码差异后独立重新编译C/Swift并执行：

- 全部既有/新增driver纯测试通过。
- 替换真实权限API的C桩通过，证明预检false、显式请求true；测试不调用系统权限API。
- 旧解析器的独立行为负控exit1、新解析器正控exit0；初始red.log中的undefined API编译错误不算行为RED。
- 固定consent.once在测试后仍不存在；文件权限/独占/复用/符号链接用例仅使用测试临时子目录。
- 日志：`/Volumes/RC500/dev/safarier/.build/automation-consent-entry-20261102/main-independent-tests.log`，exit0。

## 实际执行结果

时间为2026-11-02、Asia/Shanghai；对应日志UTC时间05:20。

| 项目 | 实际结果 |
| --- | --- |
| 候选 | 独立诊断身份sh.safarier.g1probe，非正常已安装App |
| 候选主二进制 | SHA-256 24284a9b3e279ef44e584d4fa57c45a7558aadb9dc0d2781fc59fe16c23c35f8，与10月30日最终候选一致 |
| 当前驱动 | SHA-256 a9ad5a2f0e07ef15d4550c74b57f695ff75f867a69792eeaea2108416d8c965f |
| 本次候选PID | 55101 |
| 不提示预检 | 13:20:20，-1744 |
| 一次授权请求 | 13:20:20安排，13:20:24返回0；未重复请求 |
| 真实命令回复 | OSStatus=0，结构化failure、errorCode=UNAUTHORIZED；未取得有效capabilities结果 |
| 严格验证 | 正确判失败，driver exit1，未弱化请求ID/PID/能力断言 |
| 收尾 | 对已验证本次owner请求普通终止并观察退出，无forceTerminate，无诊断进程残留 |

权限API返回0证明当时这条事件已获允许；不推断系统提示的视觉细节，也不推断今后不同代码签名/正式App身份自动获得相同授权。本轮没有再次触发授权，也没有修改TCC数据库或正常App。

持久claim保留在：

`/Volumes/RC500/dev/safarier/.build/automation-consent-entry-20261102/consent.once`

权限为0600，不能为了重试而自动删除。系统授权通过不代表应用身份校验通过。

## 当前拒绝边界与下一步

主 agent 已回读现有接收代码及本机SDK：sender EUID/PID预期SInt32、auditToken固定类型/长度与源码意图一致，不能根据UNAUTHORIZED就猜测放宽类型。

现有日志不能区分以下早拒绝条件：当前Cocoa命令/主线程/Manager上下文，以及从系统事件复制的sender属性是否完整且授权。**尚未取得实际descriptor的类型/长度及上下文判定证据，未认定根因，也没有修改产品身份校验。**

下一步应在原接收入口的私有诊断保护层补充最小的条件布尔值和静态类型/长度观测，比较当前真实事件与命令事件快照；不记录audit token原文、用户数据或事件正文，查明后沿原实现修复，不能靠移除校验/伪造proof放行。若诊断重签名导致再次需要权限，只做不提示预检并停下，不能消费本轮授权再次弹框。

首次全新构建的LaunchServices早期停滞仍是独立未解决项。本轮同一候选的一次及时启动不抵消上轮失败。正式BID唯一Manager路由、Factory/Runner输入、销毁回执与并行中文IME验收均未完成。

## 安全观测与保留边界

- 接收端31次状态样本均为inactive/accessory/0窗口/无key；无interactive handler事件、无显示/激活保护命中。本轮只允许了系统授权提示，未操作任何页面，也未使用全局输入、虚拟机或焦点/鼠标/IME回位。
- 独立只读observer共3000样本、NSApp始终nil；由于observer初始加载，其首样本晚于driver启动约273毫秒，**不称覆盖全过程**。cursor hash实际有变化；未泵RunLoop的frontPID可能陈旧，不作为焦点不变证明。本轮不是G5持续打字/中文IME验证。
- 落档前288已有仓库文件哈希不变，生产Sources/Package/原测试夹具/门禁和原私有driver未改；正常已安装App Info.plist/主二进制与候选哈希不变，相邻工作区、原10个缺失assets及skip-worktree标记保持。收尾只新增本报告、追加计划记录。
- 没有安装、commit、push或发布；原344项XCTest/9x25页面矩阵未本轮重跑。

## 证据索引

根目录：`/Volumes/RC500/dev/safarier/.build/automation-consent-entry-20261102/`

- before.json、main-review.json、main-independent-tests.log
- authorized-attempt-1-command.json、authorized-attempt-1-status.json、authorized-attempt-1-driver.log
- final-audit-before-docs.json、final-audit.json、consent.once
- 接收端：`/Volumes/RC500/dev/safarier/.build/automation-manager-entry-20261030/traces/consent-20261102-1.jsonl`

