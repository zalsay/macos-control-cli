# 第十二批收口：后台 owned 代理准备、私有控制连接取消与资源退出

收口日期：2026-10-30（Asia/Shanghai）。实现和三轮运行完成于此前开发轮次；本轮只重新核对保存的退出码、冻结源码、工具链和工作区，没有把这些记录冒充本轮重新跑出的三轮结果。

分支 `mcc-safarier`，HEAD `2f32d21248deaffd8c8c1152a39912aa46350c7e`。三名实际 Terra/high worker 实现，主 agent 独立执行全部设计与 code review；无 reviewer 子代理。

## 已接好的候选代码

- `/Volumes/RC500/dev/safarier/Sources/SafarierCore/OwnedRunnerProcess.swift`：在原 retained Foundation Process 上新增一次性终止请求、isRunning，以及只检查该子进程的有界 FD/TCP LISTEN 归属核验。只接受 IPv4 127.0.0.1、目标端口、TCP LISTEN 和正确 union kind；查询失败/截断/未知保守拒绝。不按名称或旧 PID 重建 owner。
- `/Volumes/RC500/dev/safarier/Sources/SafarierCore/RunnerLauncher.swift`：新增显式 stdin/stdout/stderr 的 owned overload，复用原 spawn 与 record-before-callback；旧 protocol 和默认 I/O 保留。
- `/Volumes/RC500/dev/safarier/Sources/SafarierNetwork/SingboxProcessManager.swift`：原 manager 内新增 owned 路径，复用配置 builder 与端口分配。固定 sing-box v1.14.4 支持 `-c stdin`；新路径以独立匿名 Pipe 送配置、最小环境、stdout/stderr null，不新增密码配置/PID 文件、不修改 quarantine、不 reap 旧 PID。不把自动化控制 FD 传给代理。配置最多 1 MiB，非阻塞写入处理部分写入、EINTR、背压、取消和预算。
- 同一 manager 以完整 OwnedIdentity 绑定 profile/ownershipID/PID/proxy。取消未 spawn 的 starting slot 也受保护；未知退出继续占槽，真实已观察退出才释放。关闭 single-flight，起点固定、重复关闭不延长预算；有界终态回执缓存不被 pendingCount 读取丢弃。TERM 仅请求本次 Process，不增加 SIGKILL 或旧 PID 兜底。
- `/Volumes/RC500/dev/safarier/Sources/Safarier/RunnerPreparation.swift`：人工与异步背景候选共用 finish；同步路径独立拒绝背景。背景先 Factory/Native/许可及参数检查，订阅只走 owned API，所有错误不退直连。资源聚合在调用时固定两秒截止，同步请求自身退出，再异步观察；迟到/nil/异常稳定为 false，不伪造已清理。
- 同文件新增私有控制 FD watcher：验证 connected AF_UNIX 后只复制自己的 CLOEXEC FD；poll 观察 HUP/ERR，不读 hello、不 shutdown 原连接，FD 由自己的 task 关闭。准备期间断线会取消准备；handoff 前停止 watcher，避免旧回调影响新 owner。它不是全局输入监听器。
- `/Volumes/RC500/dev/safarier/Sources/SafarierCore/RunnerPreparationPlan.swift`：允许正确订阅元数据，验证订阅 ID、节点名与原仓库 first-match 的完整节点值。缺失/错误 binding 不退直连；follow-Geo 仍拒绝。允许规划不是 shipping 放行。

## 主代理复核修正

1. 恢复旧人工 manager 的 deinit/stopAll 行为，不能为了 owned 模式而改变人工退出、等待和状态文件清理。纯 owned 的 deinit 仅请求自己的子进程，不等待或扫描。
2. legacy stop 在修改端口或状态前先拒绝 owned/starting 槽；跨模式并发有预留保护。
3. stopAll 覆盖未完成的 starting 槽；迟到 spawn 注册后仍立即响应已发生的取消，不能发布 ready。
4. 关闭使用共同绝对预算，修正逐项累加、重复两秒和 detached task 晚调度重新计时的问题。真实退出与“请求过退出”严格区分。
5. 不能用“能连接到端口”冒充子进程拥有监听；新增真实归属核验，拒绝其它测试 listener 和 wildcard。
6. 背景路径不能误用旧同步 sing-box/Geo；私有 socket 在准备阶段也必须响应 EOF，握手数据留给原 server。

## 保存并重新核对的验证

证据根目录：`/Volumes/RC500/dev/safarier/.build/automation-stage12-main-review/`。

| 验证 | 结果 | 能力边界 |
| --- | --- | --- |
| 最终冻结源码 | 248 个 Sources/Tests/scripts 文件；本轮 hash 重核一致 | 无中断后源码漂移 |
| 联合回归 | **3轮，每轮2,429 checks** | 含 preparation54、owned child26、owned proxy55；逻辑/私有 IPC/本次创建的 CLI fixture，不是图形验收 |
| 主代理独立 owned proxy | 18 × 3轮 | 实际私有 stdin、null 输出、环境、控制 FD 不继承、完整身份、并发 close、未知槽、迟到回执、取消；无真 sing-box |
| 实际产品对象链接的启动/控制/资源 | **80 × 3轮**，NSApplication=nil | 真实代码 + 自建 fixture，验证 early gate、握手不消费、EOF、正常/错误 owner、稳定 false |
| 实际产品对象链接的共享 watcher | **70 × 3轮**，NSApplication=nil | 停止、断线、并发、queued hello；不执行 Native 输入 |
| 原有独立 Manager/controller/policy/session/script/owned IPC 等 | 各3轮通过 | 53项合成 policy 不是53项真实 UI |
| 正常产品 / 诊断目标 | 编译链接 exit0，无 warning；符号0/5 | 诊断不运行，未执行 App GUI |
| 原有实际 Factory/Native/Entry/Model/凭据 helper | 各3轮通过 | admission 仍 unavailable，fake Security 不查真实 Keychain |
| 源码接线 | stage10=15、stage11=6、stage12=27，通过 | 结构反例，不是 OS 验收 |
| Metadata / 新 XCTest wrappers | 32项通过 / 3个 wrapper parse通过 | 完整 XCTest 当前 CLT 缺 module，未运行 swift test |
| 收口保全核对 | 154项通过 | 保存于 final-review.json；本轮核对而非新三轮运行 |

CLI fixture 仅由本次测试创建和清理；包含验证拒绝 wildcard 的自建监听负例，不能把它描述成真实隔离图形环境或真实代理验收。没有向外部代理发请求，没有访问用户的 Profile/Keychain 或发送真实键鼠。

### 保留的失败

首次新 actual-linked harness 在“先 shutdown peer、再构造要求 connected socket 的 watcher”处出现 invalidSocket。阶段标识定位为 `preclosed-false`；这是测试错误地要求构造成功，并非需要放宽生产连接检查。修正为先建立/arm watcher 再断线以测试 HUP，并单独保留已经关闭的输入在构造期或 HUP 处 fail closed 的负例。生产代码未为该失败修改。

原日志：`actual-startup-round-1-initial-fixture-failure.*`、`actual-startup-instrumented-initial-fixture-failure.*`，以及 `fixture-correction.json`。最终三轮通过，旧失败未删除。

## 未完成、不能对外承诺的部分

- 真实 sing-box 未运行；拥有 TCP listener 不等于实际 SOCKS5/上游节点功能正确或已通过签名/Gatekeeper验收。
- 忽略 TERM 或父进程崩溃/SIGKILL 后，不能据此保证代理子进程已退出。仍需隔离 G3；不得按旧 PID/名称补杀，也不能标成 cleaned。
- 原始 kernel/file/spawn 调用不能被这些 Swift 时间检查强制抢占；预算检查与晚结果拒绝不等于硬实时系统保证。
- 真实后台 AppKit 事件循环、冷/热启动、多实例接收者、原生页面动作、53项 UI policy 和其它 App 输入对照均未验收。G0完整测试/release/原打包签名亦未完成。
- NativeInputPreflight、Factory、Manager cold-launch、默认脚本门禁未改变；本批不是可安装/可用交付，没有全局输入、焦点恢复或 DOM/JS 输入兜底。

## 保全与下一步

260个基线文件中251个不变，9个限定修改；新增15个测试/脚本文件及本报告，零新增生产实现文件。原10个缺失资源与相邻 chrome-control-cli 状态保持；DeveloperDir、5个既有工具链保护文件 hash 保持。未 staging/commit/push/install/release，未改权限、TCC 或真实配置。

下一轮先检查 G0 与隔离图形验收入口，优先用不带订阅/Geo/认证的最简 Profile 收口真实闭环条件。不得拿当前日常桌面运行包含窗口激活的完整 swift test、probe 或 UI matrix，不以继续增加合成检查替代真实验收。
