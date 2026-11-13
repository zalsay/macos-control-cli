# Binder 身份与私有控制通道：headless 离线验证记录

日期：2026-11-03；仓库分支：`mcc-safarier`。主 agent 已完成本 headless 离线范围的源码复核和独立复测，复核接受范围仅限该离线组件；主 agent 源码复核记录为 `.build/automation-binder-identity-20261103/main-code-review.json`，最终保全门禁以 `.build/automation-binder-identity-20261103/main-final-audit.json` 为准。本文不将离线复核扩展为整体 Binder 或 GUI 就绪。

## 1. 设计、范围与证据边界

本轮以同一冻结 headless CLI 映像作为 controller/endpoint，运行自有、可回收的子进程与匿名 `socketpair`，验证身份与私有控制通道；不是实际 Safarier、Manager/Runner GUI 或 App/window/Space 对象。没有全局输入、监听服务或 helper，也没有执行真实 GUI、人工授权或许可放行。

直接编译复用且不修改产品的七份原源码：`AutomationChannel`、`AutomationProtocol`、`AutomationHandshake`（仅 deadline helper）、`OwnedRunnerProcess`、`RunnerLauncher`（`FoundationProcessSpawner`）、`RunnerLaunchSpec`、`SPIFeatures`。没有另写帧传输或进程执行器，没有编译含 LocalAuthentication 的完整 Core。新组件仍位于 `.build/automation-binder-identity-20261103/` 隔离目录，本轮未接入正式 `Sources`、Manager 或 `RunnerMain`；产品文件未因本组件改动。真实 AppBundle 资源校验和 GUI Binder 尚未实现。

初始 presence 是固定有界的**未认证引导**，不授权任何操作；controller 在其后核验原 retained owned child 的真实 kernel peer，再进入 `hello/proof/ack`。endpoint 的 parent 来自实际 `getppid()`、同自身 pin 的映像和内核身份观察，不来自消息，且不产生 parent cleanup 权。已认证事务的 self/peer/resource 证据在收发前后复验；消息中的角色、PID、nonce 或 hash 不单独授权。

双方事务角色从可信启动上下文绑定：持原 owned child 的本地角色为 controller，actual-parent 分支本地角色为 endpoint；只能发送本地 role、接收对端 role。`AuthenticatedConnection` 的 `commit`、状态及底层持有对象为 private；显式 in-flight gate 在跨 `await` 期间拒绝重入、poison 并关闭，不把 actor 本身当作不可重入证明。正常 `finished` 经身份与状态校验后，parent 执行 `shutdown(SHUT_WR)`，保持读端/进程存活；endpoint 完成发送后身份复验、读取 EOF 并退出；parent drain 只允许 EOF，观察**原 retained owned child** 退出 0 后再完整关闭。失败路径先关 IPC，再按 fresh owned identity 做有界清理；不忽略 ENOTCONN，不扫描 PID 或凭观察对象获得清理权。

`ready`、`arm`、`input` 等不提供 GUI 功能。`DENIED_NO_GUI_EVIDENCE` 为本地拒绝诊断及 poison/EOF，**不是发送给对端的结构化 wire error**。

## 2. 分开记录的正向与静态验证

以下路径相对仓库根目录，均为已有离线证据；本文件未复制 nonce、audit token 或原始帧。

| 验证者/范围 | 结果与边界 | 证据 |
|---|---|---|
| Worker：当前离线测试套件 | **69 checks 通过**。涵盖纯 codec/model、方向谓词、in-flight gate 及原 channel/EOF/deadline 等测试；不能误称全部 69 项都是纯模型，也不等于真实认证事务的并发或取消对抗。 | `.build/automation-binder-identity-20261103/control/direction-unit-green.log`、`DIRECTION-HANDOFF.md` |
| Worker：最终 headless normal | 新建私有 root 下连续 **3/3 轮退出 0**，endpoint 收到 parent EOF，原 owned child 自然退出；结果仅限该 CLI。 | `control/direction-normal.log`、`control/direction-normal-root.json` |
| Worker：最终 headless Swift ASan | 单独构建的 Swift ASan headless 往返 **1 轮退出 0**；不是 UBSan 或穷尽内存安全证明。 | `control/direction-asan.log`、`control/direction-asan-root.json` |
| 主 agent：独立重编译并运行离线测试套件 | **69 checks、build/test 均退出 0**；该套件同样包含 codec/model 与原 channel 等测试，不能称全部是纯模型。 | `main-review/model-test-result.json`、`main-review/model-tests.log` |
| 主 agent：独立重编译及正常往返 | 与 worker 分开编译最终 C/Swift，**normal 3 轮退出 0**；这是独立重建证据，不替代最终主审计。 | `.build/automation-binder-identity-20261103/main-review/independent-build.log`、`main-review/independent-roundtrips.json` 及各轮 stdout/stderr |
| 主 agent：独立 Swift ASan 往返 | 独立构建的 **Swift ASan 1 轮退出 0**，与 worker 的 ASan 结果分开计数。 | `main-review/independent-roundtrips.json`、`main-review/asan-1.stdout`、`main-review/asan-1.stderr` |
| C collector：sanitizer 与独立 preserved | C identity 既有 normal 与 **ASan+UBSan** fixture 测试，主 agent 独立 preserved 复测记录通过；该 C 验证不等于 Swift ASan。 | `identity/HANDOFF.md`、`main-review/identity-independent.log` |
| 主 agent：Clang analyzer | C 静态分析正式记录 **exit 0、diagnosticCount 0**；plist 中 diagnostics 数组为空。该结果不替代最终保全门禁。 | `main-review/identity-analysis-result.json`、`main-review/identity-analysis-final.plist`、`main-review/identity-analysis-final.log` |
| identity 确定性快照变更：主 agent 独立复测 | 新私有 root 下 normal 与 **ASan+UBSan**：未变更为 `BI_OK`；同字节不同 inode 的文件 rename 和 ancestor subtree rename 均为 `BI_CHANGED`，两项拒绝的输出哨兵完整不变。测试在受控回调时点发生，不证明原子 fd-exec 或瞬态 TOCTOU 不存在。 | `main-review/snapshot-mutation-independent.json`、`main-review/snapshot-mutation-independent.log`、`identity/snapshot-mutation-20261103.receipt`、`identity/snapshot-mutation-20261103.sha256` |

表中 `control/`、`identity/` 和 `main-review/` 的简写均位于 `.build/automation-binder-identity-20261103/` 下。源码及原始输入摘要见 `control/DIRECTION-SHA256SUMS`、`control/DIRECTION-ORIGINAL-SOURCES-SHA256SUMS`；normal、ASan 和各负例的 root/inode/制品摘要见 `control/DIRECTION-ROOT-RECEIPTS.json`。这些是不同轮次的证据，不把模拟 PID 重用、测试资源或单次成功当作真实 PID 重用、完整 AppBundle 或所有竞态均已解决。

### 主 agent 的独立 manifest 与依赖/符号检查

主 agent 的 manifest 检查分别记录 identity **18**、control **59**、`DIRECTION-ORIGINAL-SOURCES-SHA256SUMS` **10** 和 `source-SHA256SUMS` **7** 项，四组退出码均为 0、摘要一致；详见 `main-review/manifest-checks.json` 及各检查日志。这是对所列制品的完整性核对，不是最终主审计结论。

主 agent 对独立构建的直接依赖及 `nm` 未定义符号的受限扫描未发现所检查的 GUI/全局输入禁止项。原始源码扫描有一处命中：原有 `Sources/SafarierCore/SPIFeatures.swift:20` 注释提到 `WKWebView`；主审将其判定为 **comment-only**，不是可执行 API 引用。原始命中记录 `main-review/no-gui-input-dependency-audit-raw.json` 保留，归类结果见 `main-review/no-gui-input-dependency-audit.json`，直接依赖与符号明细见 `main-review/direct-dependencies.log`、`main-review/undefined-symbols.log`。该定向扫描不证明运行环境或完整产品中不存在所有 GUI 路径。

### 主 agent 的六项独立真实通道负例

主 agent 为下列每项在新建的 0700 HOME root 下独立重编译并执行；六项均为预期 **parent 退出 78、断言通过**。78 仅表示所要求的负例拒绝，不能称为一般业务成功。证据为 `main-review/independent-negative-results.json`、`main-review/independent-negative-receipts.json` 和各 `NEG_*.stdout` / `NEG_*.stderr`。

| 独立负例 | 断言边界 |
|---|---|
| `NEG_ROLE` | 接收方向错误 role 被拒绝；原 owned child 记录退出 78。 |
| `NEG_LOCAL_ROLE` | actor 发送方向错误 role 被拒绝；原 owned child 记录退出 78。 |
| `NEG_ARM` | 本地 `DENIED_NO_GUI_EVIDENCE`、poison/EOF；原 owned child 记录退出 78，不是 wire 结构化 error。 |
| `NEG_RESOURCE` | 测试资源变更后身份/资源检查失败；原 owned child 记录退出 78。 |
| `NEG_EXTRA_AFTER_FINISH` | parent 拒绝额外帧并退出 78；child 自身退出 **0**，但整个会话失败。 |
| `NEG_CLEANUP_NO_PROOF` | 记录 `cleanup_unconfirmed`，未请求 TERM；测试 parent 保有原 owner 后观察到 child 自然退出。不能把未确认时刻改写为已清理。 |

## 3. 最终方向绑定版本：13 类负例与实际 cleanup

各行证据路径均为 `.build/automation-binder-identity-20261103/control/direction-neg-<名称>.log`，对应 root receipt 为同名前缀的 `-root.json`。测试专用编译标志不属于正常运行模式，不提供 fake identity positive。以下 controller 均按预期**失败退出 78**；该数值是负例拒绝，不是正常成功。

| 负例名称 | 已记录的现象和原 owned child 结果 |
|---|---|
| `arm` | 本地固定拒绝诊断，poison/EOF；child 退出 78、非信号，未请求终止。 |
| `ready` | 同上；child 退出 78、非信号，未请求终止。 |
| `input` | 同上；child 退出 78、非信号，未请求终止。 |
| `nonce` | 错误关联被拒绝；child 退出 78、非信号，未请求终止。 |
| `replay` | 请求重放被拒绝；child 退出 78、非信号，未请求终止。 |
| `role` | 测试专用原始注入错误对端 role，接收方向拒绝；child 退出 78、非信号，未请求终止。 |
| `local_role` | 正常 actor 发送路径试图冒充对端 role，在发送方向拒绝；child 退出 78、非信号，未请求终止。 |
| `eof` | 提前关闭被拒绝，不以 peer 不可用降级；child 退出 78、非信号，未请求终止。 |
| `timeout` | 测试对端超出期限后失败；child 退出 78、非信号，未请求终止。 |
| `resource` | 私有 fixture 在 pin 后故意变更，资源复核失败；child 退出 78、非信号，未请求终止。 |
| `cleanup_term` | 故意停滞的原 owned child 经 fresh identity 匹配后由原 owner 请求 TERM；观察到 **status 15、signal=true**。这是受控终止，不是自然退出 0。 |
| `cleanup_no_proof` | 故意缺失初始身份依据时记录 **cleanup_unconfirmed**，不请求终止；测试专用 parent 随后继续保有原 owner 并观察到 child 退出。正常 CLI 进程退出后不能声称仍保有该活 handle。 |
| `extra_after_finish` | parent drain 收到额外帧而拒绝、退出 78；endpoint 自身退出 0、未请求终止，但**整个会话失败**。 |

负例资源变更只发生在独立测试 fixture。一般情况下若 fresh birth/path/UID 等不足以匹配原 owner，或有界等待后未观察到退出，应保留 `cleanup_unconfirmed`，不得把未决写成自然退出。

## 4. 历史失败与未开放项

旧顺序中 parent 收到 `finished` 后完整关闭，endpoint 的发送后 peer 复验可能晚于关闭；失败被保留而非被后续通过覆盖。例：`control/full-final-normal.log` 首轮失败，`control/cleanup-normal.log` 的后两轮失败；`control/full-diagnosis.log` 的复现定位到 `verification-send-after-finished`。主 agent 独立的 `main-probes/peer-halfclose.c`、`main-probes/peer-halfclose.log` 支持所批准的写半关闭顺序；当前版本在此基础上继续要求真实 peer 校验，不采用重试或放宽身份检查。

LOCAL peer 表示 socket last-owner/use，**不是逐消息永久身份认证**；不能证明能防主动 FD 转交或恶意同 UID 调试/运行时篡改。文件快照和 static Security 路径检查不证明原子 fd-exec 或瞬态 TOCTOU 不存在，也不是完整 AppBundle 资源绑定。真实认证事务的取消和并发对抗尚未覆盖；channel 取消与 gate 争用的离线测试不能代替它们。 identity 的同字节不同 inode 文件替换及 ancestor subtree rename 受控补充测试已由主 agent 独立复测，结果见上表；其确定性回调覆盖不改变原子 fd-exec/瞬态 TOCTOU 的限制。

真实 Manager/Runner GUI、人工授权、App/window/Space、ready、armed、G1、G5、input、shipping 和 live adapter **均为 false/未放行**。离线 transport identity 成功不是 GUI-ready。主 agent 已复核并接受的范围仅为 headless 离线组件；最终保全门禁以 `.build/automation-binder-identity-20261103/main-final-audit.json` 为准，不能据此推导整体 Binder 或 GUI 放行。
