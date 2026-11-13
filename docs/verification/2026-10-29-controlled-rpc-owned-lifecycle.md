# 第七批：受控 RPC 与自有子进程生命周期

日期：2026-10-29（Asia/Shanghai）

## 结论与边界

本批候选源码及以下无 GUI 验证已完成：受控通道支持有界并发、乱序关联、cancel/close 独立容量；启动绑定本次实际创建的 Foundation Process，支持有界退出观察。**不是完整 AppleScript 页面控制已可用，也不是鼠标/键盘非干扰的图形验收通过。**

生产 Runner 仍只启动 unavailable 服务，Manager ScriptService、WebView 工厂和 NativePageInput admission 均保持原硬拒绝。没有将虚拟 handler 的 nativeDelivered、cleanup receipt 或 synthetic policy evidence 当作真实输入/销毁/UI 安全证明。

工作仓库：`/Volumes/RC500/dev/safarier`；分支 `mcc-safarier`；HEAD `2f32d21248deaffd8c8c1152a39912aa46350c7e`。未提交、推送、安装或发布。保留前六批未提交改动、其他 checkout 和 10 个原本缺失的 sparse assets。

## 源码路径与复用

1. `/Volumes/RC500/dev/safarier/Sources/SafarierCore/AutomationRunnerClient.swift`
   - 单 reader，pending 至多 8 普通 + 2 cancel/close；写入至多 2 普通 + 2 控制，控制队列优先，不把 cancel 排在已卡住的 handler 后等待。
   - 严格复用 AutomationCodec、现有结果形状和 Profile/Runner instance 校验；未知、重复、迟到或不匹配回包关闭连接，所有 pending 只完成一次。
   - 实际发送前复核同步取消标记、绝对 monotonic deadline。发送前失败为无副作用；已尝试发送的变更失败为 INDETERMINATE_RESULT / possible / non-retryable，不透明重试。
   - correlation-only sent ID tombstones 上限 4096；普通请求限 4094，保留两个 cleanup ID。硬上限耗尽关闭自己的通道，不驱逐历史 ID。此集合不缓存结果，也不替代既有 session replay cache。
   - 持有 OwnedRunnerProcess；握手失败只关闭自己端点并有界观察该 child；deinit 主动关通道。closeAndWait 返回实际 ProcessExit?，nil 不等于 cleaned。
2. `/Volumes/RC500/dev/safarier/Sources/SafarierCore/AutomationRunnerServer.swift`
   - 一次严格 hello/ready 握手与单 reader；默认 8（允许配置 1...32）普通 handler + 2 控制容量；有界分级写队列。
   - handler 返回 AutomationOutcome，回复 ID 由 server 从对应 request 绑定。不是另一套 session machine、权限服务或输入实现。
   - EOF/取消/超时/坏包关闭自己通道，取消自己任务，独立调用一次 shutdown hook；不等待不配合取消的 handler。hook 被调度不等于它完成了清理。
   - 保留旧 JSON 坏包固定 nil requestID / INVALID_REQUEST 诊断；之后失效关闭。诊断不调用 handler、不新增队列，writer 预留已满直接关闭，否则最多 2 秒；握手错误仍静默失败。旧 unavailable 服务收到坏包后继续读的行为不用于新的 owned 服务。
3. `/Volumes/RC500/dev/safarier/Sources/SafarierCore/AutomationRunnerBootstrap.swift`
   - unavailable 实际入口复用上述唯一 server；backend/uiPolicy/coldLaunch 仍 unavailable/unverified/unverified，其余动作仍 BACKEND_UNAVAILABLE。
4. `/Volumes/RC500/dev/safarier/Sources/SafarierCore/OwnedRunnerProcess.swift`
   - 保存实际 Process 对象和不可变 ownership UUID，不提供从任意 PID 创建的公开构造器，不发任何信号。
   - terminationHandler 将退出记录到受锁保护的一次状态；先记录再调用外部 onExit，外部阻塞不妨碍观察。
   - waitForExit 使用实际 monotonic 时间、有界可取消轮询，无持续注册的 waiter/observer 任务；超时 nil，取消抛错，重复观察稳定。
5. `/Volumes/RC500/dev/safarier/Sources/SafarierCore/RunnerLauncher.swift`、`/Volumes/RC500/dev/safarier/Sources/SafarierCore/SafarierWorkspace.swift`
   - 普通/owned 启动复用原 Foundation Process 创建和同一组 spec/input、锁、许可、环境构造，不复制第二条普通启动实现。
   - 旧 spawner 的 owned API 明确 unsupported，不调用旧 spawn 降级。后台仍 about:blank、私有 connected stdin、原 Profile 许可和自身 SAFARIER_HOME；不认领旧 PID 文件。

## 主代理复核及 RED → GREEN

生产实现由两名实际 turn_context 为 gpt-6.1-terra/high 的既有 worker 完成。所有设计/代码 review、独立故障用例和集成验证由主代理执行，无 reviewer 子代理。

主代理发现并交回 Terra 修正：

- 取消标记仅在注册 continuation 检查，排队发送可能抢在 actor 的取消回调前执行；改为最终发送前复核。
- 相对 sleep 从 timer task 开始运行才计时，不能防止已过期的排队发送；改为绝对 deadline，并在发送/接收边界检查。
- 弱引用 reader 仍持有通道、client 丢弃未关端点；主代理真实 Foundation helper RED 为 `client deinit closes channel and own child exits`，最终同一独立测试连续三轮通过。
- 生命周期关联上限也拦住 cancel/close；worker 的真实 4094-request 预算反例 RED，最终两个 cleanup 预留及硬上限关通道通过。
- 提取 server 后丢失旧坏包固定回复；主代理原 117 项 wire 联合回归 RED 为 `malformed EOF`。修复 server 诊断边界后保留原测试，最终三轮全部通过，没有弱化断言。

证据：`/Volumes/RC500/dev/safarier/.build/automation-stage7-main-review/`。保留 `independent-client-initial.*`、`pre-malformed-fix-combined-red.*` 与最终通过日志。测试驱动曾漏传 policy inventory 参数，产生 harness Index out of range；根因是主代理调用参数，不是产品变更，保存为 `harness-missing-policy-argument.*`，补齐参数后全部三轮重跑。没有把失败日志当成功忽略。

Worker 补充证据：`/Volumes/RC500/dev/safarier/.build/automation-stage7-worker-a/`、`/Volumes/RC500/dev/safarier/.build/automation-stage7-worker-b/`；不以 worker 自报替代下面主代理验证。

## 冻结后验证

### 联合测试：连续三轮，每轮 2,115 项

| 类别 | 每轮检查数 |
|---|---:|
| Protocol | 340 |
| Channel | 28 |
| Wire | 117 |
| Controlled Runner | 56 |
| Script | 59 |
| Manager launch | 64 |
| Background policy | 117 |
| Session machine | 354 |
| UI boundary（纯路由） | 395 |
| Runner controller（注入 sink） | 317 |
| Native preflight（无事件） | 60 |
| Snapshot store（私有文件） | 69 |
| Multiplex | 35 |
| Owned process | 104 |

Multiplex 预算场景实际发送 4094 个普通请求，再验证两个 cancel 和硬上限。所有“输入”请求仅发给 Foundation fixture，无 WebView、页面导航或原生输入。

### 主代理独立验证：同一冻结源码，以下各连续三轮

| 类别 | 每轮检查数 | 真实边界 |
|---|---:|---|
| Owned process | 19 | 本次实际 Foundation child，自然 EOF、退出观察、取消/超时、不调用旧 spawn |
| Controlled server | 13 | 实际 socket、乱序、独立控制、重复 ID、关闭不等不配合取消的 handler |
| Controlled client | 20 | 实际自身 helper、阻塞导航 stub、cancel、未知/错误/重复回复、发送歧义、释放时 EOF |
| Controller | 67 | 20 次排队取消、300 调用容量反例，注入 sink |
| UI boundary | 225 | 无 WebKit 对象/系统动作 |
| Session machine | 356 | 100 个 foreign-ticket 反例，无 I/O |
| Policy | 1001 | 53 项 inventory，synthetic evidence only |
| Script coordinator | 281 | 并发 64、立即取消 128，无真实 Apple Event |
| Native preflight | 133 | 无 AppKit/WebKit/cursor/input |
| Snapshot store | 88 | 真实私有 POSIX/ACL fixture，无 GUI |
| Passive caller adapter | 39 | synthetic descriptors，不发送/执行 Apple Events |

另有 Manager launch reducer 299,592 次转换、metadata/sdef 32 项检查通过；仅测试 reducer 或输出私有 metadata，不启动 App、不注册脚本入口。

### 普通产品和早期拒绝路径

- 冻结源码的 SwiftPM 普通 Safarier 产品编译链接 exit 0，无 warning；没有执行该产品。
- 当前 CLT 的 ManifestAPI private/public interface 不匹配仍用**仅单命令有效**的诊断 VFS overlay 绕开，未修改系统文件或开发目录；不能表述为默认工具链已修复。
- 链接本次普通产品的实际对象，运行仅调用拒绝入口的两个小 CLI，三轮通过：Factory 每轮 8 个 early-denial（credential/privacy 调用 0），NativePageInput admission 保持拒绝；未创建 NSApplication/WebView/window。
- 新 XCTest wrappers 仅语法 parse，shell 脚本 bash -n、git diff --check 通过。实际 import XCTest 仍报 `no such module 'XCTest'`，未运行正规 XCTest 或原 AppTests。

复核入口：

```sh
cd /Volumes/RC500/dev/safarier
python3 /Volumes/RC500/dev/safarier/.build/automation-stage7-main-review/Validate.py
python3 /Volumes/RC500/dev/safarier/.build/automation-stage7-main-review/FinalReview.py
```

Validate 重建独立库/fixtures 后执行三轮；FinalReview 检查命令结果、冻结 hash、修改范围、原 gates、工具链和自有 helper 收尾。具体每条构建/运行 argv、stdout、stderr、exit 都在同目录，不是用此文档代替原始证据。

## 安全限制和后续缺口

- 本轮不运行 App、真实 GUI/probe/cursor/键鼠/Apple Events，不访问真实 Profile，不改变系统权限或工具链。无全局鼠标、键盘、System Events、DOM/JS 输入兜底；不激活窗口，也不“抢焦点再还原”。
- channel close 是请求 Runner 停止的条件，不是已退出、已销毁页面或 cleaned 的证明。未观察到退出仍未知；没有强杀或遍历其他 Runner 的兜底。
- Swift task cancellation 不是原生动作撤销证明；不配合取消的 handler 可继续到其返回，测试会明确释放自身 gate。实际输入关闭/销毁和零 click/drop 仍待隔离图形验收。
- 真实专属 BrowserSession/Window/Page UUID、Profile 权限重读/撤销订阅、controller/native driver/snapshot store、Manager 与服务通道的整链接线尚未完成。当前 unavailable handler 不得冒充这些接线。
- G0/G1/G2、53 项真实 UI 能力与非干扰验收均未放行。重复 Foundation 测试与产品编译不能证明你在其他 App 使用鼠标键盘时，真实页面操作已安全可用。
