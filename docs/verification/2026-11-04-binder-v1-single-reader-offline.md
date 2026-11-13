# v1 single-reader 与 kernel fixture：验证记录

日期：2026-11-04。Main 唯一 reviewer，`main-code-review.json` 的 `acceptedStagedOfflineScope=true`、`positiveProductionWiringApproved=false`、`productSourcePromotionApproved=false`，且范围内未解代码项为空。最终审计引用路径：`.build/automation-binder-v1-seam-20261104/main-final-audit.json`。本记录不声称产品推广、真实 GUI 或生产授权。

## Main 独立程序：58 个，未混 worker 或前轮

| 来源 | 次数 | 边界与证据 |
|---|---:|---|
| 原始 v1 baseline | 6 | 原 channel/server 基线；独立于 staged 测试 |
| Unit 1 mechanics | 24 | 12 场景 × normal/ASan，包含 pipeline、reader 冲突、foreign token、drop、EOF、cancel、duplicate、noncooperative barrier |
| Unit 1 legacy | 6 | 3 场景 × normal/ASan |
| Unit 2 kernel/API/cleanup | 22 | `main-review/kernel-independent/summary.json` 与 `results.json` |
| **合计** | **58** | 仅 main 本轮顶层程序 |

Unit 2 的 22 次明细：真实 C positive normal 3 + ASan 1；birth 精确 `BI_INVALID`、fixture-sleep cancel、EOF、timeout 各 normal + ASan 共 8；取消 caller 的自然退出/TERM cleanup 各 2 共 4；classifier/CLOEXEC 各 2 共 4；DYLD 拒绝 2。负例 fixture 父进程 exit 0 表示断言正确，不是业务成功；cleanup/DYLD 的预期 exit 78 亦不是业务成功。

## 源码、协议和冻结

- Unit 1 `worker/attempt-019`；真实 kernel fixture `worker/attempt-026`。Main 核验 019 核心和原 freeze040 C、bridge、bundle pin、owner、`PrivatePair`、spawner 前缀原样。
- main 独立 kernel 镜像无只读 test hook、无直接 GUI/Input/权限/LS 符号，三个 collector 各一个。只使用原 v1 hello/ready/request，不加入私有帧；phase token 只表示 reader/phase ownership。
- 原有错误证据保留：worker attempt-002 是手写顺序模型，**不是有效行为 RED**；attempt-008、014、017 分别保留 observed EOF 前准备、断连期间取消、noncooperative caller 有界性问题的行为 RED。worker 运行次数不加入上表。
- 实际 retained owner 清理以其退出回执和 fresh metadata 为依据；`freshProof` 与 `terminationRequested` 是实测字段，不预设为 true。

## 保留限制

- fixture handler 不逐请求 C 重验，不是 live production identity/repository/lock context 贯穿 request/service/page 的证明。下一步须单独设计 generation-bound 原身份、repository 和原 held lock 生命周期，以及逐请求重验和失效清理。
- `cancel-verifier` 取消 fixture 的独立 sleep，不能推断 C 调用可中断。非合作 callback 可在 caller 返回后存活；不声称 quiescence 或 leak-free。
- 同对象 lease 不能撤销外部 raw fd 或防同 UID 恶意转交；可观察 EOF 仅支持 admission 前观察到失败时 prep=0，缓冲后隐藏 EOF 或后续断连不能倒推。HUP 不证明对端存活。
- OS write 与 deadline 检查不原子；不声称普遍的物理截止后零字节。无 GUI、人工授权或生产 wiring 结论。

## 执行纪律与门禁

**`currentPhaseClean=false`。** 本轮发生一次只读 PID 扫描，违反 contract；未观察到基于扫描的 kill。扫描不是 ownership/退出/无残留证据；仅 retained `Popen` 或 `OwnedRunnerProcess` 及退出回执可证明相应退出。此前 `/tmp` 删除事件仍未解决，与本次只读扫描分开记录。

`fullP1`、`G1`、`G5`、`input`、`shipping`、`liveAdapter`、`GUIExecutionAuthorized`、`manualGrant`、`GUIReady`、`ready`、`armed` 全部为 false；production composition port 保持 unavailable。无任何 gate 因上述离线验证打开。
