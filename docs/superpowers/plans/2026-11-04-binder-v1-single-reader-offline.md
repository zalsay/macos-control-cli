# v1 single-reader offline：计划与验收状态

日期：2026-11-04。Main 已接受 staged offline 范围，无范围内未解决代码项；未批准生产 wiring、产品源码推广或 GUI。结果以 `.build/automation-binder-v1-seam-20261104/main-code-review.json` 为准，最终审计引用路径：`.build/automation-binder-v1-seam-20261104/main-final-audit.json`。

## 已证实的 Unit 1：reader/handoff 与 v1

- [x] 沿原 channel/readQueue 和 server/request-loop 做 staged 改动，保留原 codec、protocol、bootstrap 和 legacy 路径；冻结 `worker/attempt-019`。
- [x] 用真实 admission 观察验证 queued-before-claim、public alias、并发 lease 和 sticky close；serial queue 本身不称为排他。
- [x] 验证一次 hello、ready 后 preparation/request loop、pipelined 首 request、foreign pending/handoff 不损害原 session、same-owner duplicate/drop、观察到的 EOF 和取消。
- [x] noncooperative preparation 的 caller 可有界返回；callback 本身可能继续存活，不声称 quiescence。leased dispatch/send/commit 使用同一 lifetime 的同步检查；OS write 与期限不原子。
- [x] Main 独立 mechanics 24 + legacy 6；原始 v1 baseline 另 6。未混入 worker 次数。

## 已证实的 Unit 2：真实 kernel fixture

- [x] Main 授权预建 HOME 根；所有新 fixture 在 pinned 串行运行前构建和签名。冻结 `worker/attempt-026`；没有推广产品源码。
- [x] 复用 freeze040 原 C、bridge、bundle pin、owner、`PrivatePair` 和 spawner 原始前缀，以及 Unit 1 的 019 核心；普通 kernel 镜像无只读测试 hook、无直接 GUI/Input/权限/LS 符号，三个 collector 各一个。
- [x] 真实 self、实际 parent、原 owned child、peer 和 bundle 检查使用 v1 hello/ready 的 socket 使用；没有新私有帧或假身份批准。birth 负例严格 `peer + BI_INVALID`；EOF/timeout/cancel 及 cleanup、CLOEXEC、DYLD 拒绝有独立测试。
- [x] Main 独立 22 个程序：kernel positive normal 3 + ASan 1 = 4；birth、fixture-sleep cancel、EOF、timeout 各 normal + ASan = 8；自然/TERM cleanup 各 2 = 4；classifier/CLOEXEC 各 2 = 4；DYLD 拒绝 2。
- [x] Main code/design review 接受 staged offline 范围，记录无范围内未解代码项；不代表 positive production wiring 已获批准。

## 后续工作（未授权、未完成）

- [ ] 设计和验证同一 generation-bound 身份、repository 与**原持有 lock**跨 request/service/page 的完整生命周期。
- [ ] 实施并独立验证逐请求 C 重验、跨 await 和 commit 的失效处理、owned resources 的 quiescence 与 owner-only cleanup。
- [ ] 分别获得任何产品源码推广、生产 wiring 和 GUI/人工授权；本计划不打开任何门禁。

## 纪律和证据限制

`currentPhaseClean=false`：本轮一次只读 PID 扫描违反 contract；没有观察到基于扫描的 kill，扫描不能证明所有权或退出。退出只能以 retained `Popen`/`OwnedRunnerProcess` 和退出回执证明。此前 `/tmp` 删除事件仍未解决，不与本次只读扫描合并或清除。所有 gate（fullP1、G1、G5、input、shipping、liveAdapter、GUIExecutionAuthorized、manualGrant、GUIReady、ready、armed）保持 false。
