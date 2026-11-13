# v1 single-reader seam 与真实 kernel fixture：离线设计和结果

日期：2026-11-04。**Main 已接受 staged offline 范围**，未批准 positive production wiring 或产品源码推广。Main 唯一 code/design reviewer；审查结论见 `.build/automation-binder-v1-seam-20261104/main-code-review.json`，最终审计引用路径为 `.build/automation-binder-v1-seam-20261104/main-final-audit.json`。本阶段证据不构成 GUI、人为授权或生产能力。

## 原路径和 staged 边界

原 `AutomationChannel.receive()` 的 serial `readQueue` 允许多个调用排队，并非排他所有权；原 `AutomationRunnerServer.serve()` 自行读取一个 v1 hello、发送 ready，然后进入 request loop。原 App 的非 hard-deny 分支先进入 preparation，再由 service 开始 handshake；仅在旧 `serve()` 内增加检查无法保护前面的准备。当前产品硬门禁不变，`ProductionCompositionPort` 保持 unavailable。

Unit 1 冻结在 `worker/attempt-019`：沿原 channel framing/readQueue 和 server request loop 添加 channel 对象级 reader lease 和一次性 phase handoff；legacy 非 lease 路径保留。claim 前已有排队或活动 receive 时拒绝并关闭；claim 后同 channel 的 public receive 别名或并发 lease receive 被拒绝并 sticky close。foreign token 只关闭错误接收方，不消费或关闭无关原 session；同 owner 的重复、过期或丢弃关闭自身 session。hello 只读取一次，暂停核验后发原 v1 ready，再进入 preparation 和共享 request loop；pipelined 首 request 不被第二个 reader 消费。wire token 仅代表读取/协议阶段所有权，**不是 kernel 身份、GUI 或授权证明**。

Unit 2 冻结在 `worker/attempt-026`：`V1KernelFixture.swift` 是明确的 fixture-only adapter；复用原 `KernelIdentityBridge`、`BundleResourcePin`、C collectors、`OwnedRunnerProcess`、`PrivatePair` 和原 spawner 前缀。端点读取真实 hello 后检查实际 self、parent、peer 和 bundle，检查成功后发送原 ready，并在内存 preparation 计数前重新检查；控制器读取实际 ready 后检查 self、retained owned child、peer 和 bundle。仅以 v1 hello/ready/request 使用 socket，不引入 presence/proof/ack/ping/finish 或其他私有帧。prepare callback 的非读取 inspector 复制描述符由其自身持有，以免调用方先退出时关闭正在使用的 fd。collector 失败关闭自身通道；birth 负例严格要求实际 C `peer + BI_INVALID`，不将 `BI_EXPIRED` 或 `BI_IO` 算作成功拒绝。

认证 frame 使用同一原始绝对预算不续期，<=3 秒，fixture lifetime <=45 秒；C 期限从同一剩余预算派生。原 retained owner 和 fresh metadata 控制 cleanup；不使用 wire PID、扫描结果或观察到的 PID 建立 ownership。无法抢占的 OS/C 调用仍是限制。

## 主独立结果与限制

Main 的 58 个顶层程序只包括：原始 baseline 6、Unit 1 mechanics 24 + legacy 6、Unit 2 真实 kernel/API/cleanup 22；不混入 worker 或前轮次数。Unit 2 的 22 次包括正例 normal 3 + ASan 1；birth/cancel/EOF/timeout 各 normal + ASan 共 8；取消 cleanup 自然退出/TERM 各 2 共 4；classifier/CLOEXEC 各 2 共 4；DYLD 拒绝 2。负例 fixture 父进程 exit 0 仅表示断言成功；cleanup 和 DYLD 的预期 78 不是业务成功。详情见 `main-review/kernel-independent/summary.json`、同目录 `results.json` 及 `main-code-review.json`。

- handler 目前只做内存计数并返回 unavailable，**不逐请求执行 C 重新验证**；结果不是完整 live production context lifetime 证明。
- `cancel-verifier` 取消的是 fixture 的独立 sleep，不能证明 C 系统调用可中断。非合作 callback 可在 caller 返回后继续存活；不能声称完全 quiescent 或无泄漏。
- lease 只约束同一 channel 对象的 API，不能撤销事先复制的 raw fd，也不防恶意同 UID 转交或直接读取。
- 仅在 preparation admission 前已观察到的 EOF、取消、到期或无效状态，要求 prep=0、handler=0；隐藏于缓冲数据后的 EOF 或 admission 后断连不能倒推 prep=0。HUP 仅是拒绝提示，不是 peer-liveness 证明。
- deadline 检查与 OS write 不原子；同步检查和关闭不证明物理上绝无截止后的字节。

## 仍需单独授权的下一步

在任何 production wiring 前，必须设计并验证同一 generation-bound 身份、repository 和**原实际持有的 lock**贯穿 request、service、page 的生命周期；逐请求重验、跨 await/commit 失效、资源 quiescence 与 owner-only cleanup 均须有独立证据。不能将本 fixture 的一次性检查、路径、PID、nonce、phase token 或机械 preparation callback 当作生产 authority。生产/GUI 门禁不因本结果打开。

## 执行纪律

`currentPhaseClean=false`：本轮发生一次只读 `ps` 进程扫描，违反禁止 PID 扫描的 contract；未观察到基于该扫描的终止。扫描不构成 ownership、退出或无残留证据；这些事实只能依据实际 retained `Popen`/`OwnedRunnerProcess` 和退出回执。本事件与此前 `/tmp` 删除事件分开记录；此前事件仍未解决。
