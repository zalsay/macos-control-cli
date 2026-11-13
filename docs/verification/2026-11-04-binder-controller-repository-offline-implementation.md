# Binder controller repository lifetime：离线实现与验证记录

日期：2026-11-04  
范围：Safarier 已批准的 controller repository lifetime **离线 fixture 副本**；主 agent 独立复核及验证。本文不代表生产接线、GUI、原生输入、发布或部署验收。

## 源码与变更边界

- 本单元最终候选为 `.build/automation-binder-controller-impl-20261104/worker/attempt-052/src/`；`attempt-053/src/` 为无 TEST_ONLY 编译副本。两者 **30 个源文件逐项 SHA-256 相同**，差异检查见 `worker/attempt-054/check-source-delta.log`。
- 对照 `.build/automation-binder-writequeue-impl-20261104/worker/attempt-017/src/` 的 29 个文件，25 个字节不变；4 个派生 Swift 文件有本单元修改：`AutomationRunnerServer.swift`、`AutomationChannel.swift`、`AutomationHandshake.swift`、`FrameDeadline.swift`。另新增真实 `AutomationRunnerClient.swift` 的 fixture 抽取副本，复用原 actor 核心，不是另造 client。
- 原真实 client 源为 `Sources/SafarierCore/AutomationRunnerClient.swift`，236 行、SHA-256 `1aeec48cfb9d2607764c7ba8fdeb522a5249617a448dd90c437f37d44bea4c51`；原 workspace/launcher startup 为 59–88 行，映射见 `main-review/original-client-source-map.json`。最终抽取副本 SHA-256 为 `7f526666ab0676ed69ae8579501ba5448eb762f0ef29cbf18d57658d916c0b52`。
- 原 C、`RepositoryBindingProvider`、`ProfileLock`、`KernelIdentityBridge`、`OwnedRunnerProcess` 和原 `V1KernelFixture.swift` 与 017 对照字节一致；runner 原 `finishWrite` 函数体保持一致。相关完整性检查见 `worker/attempt-051/integrity.log` 和最终源差异记录。本单元没有修改生产 `Sources/`、`Tests/` 或 `Package.swift`；这不表示原工作区无既有未提交改动。
- 047 至 052 的唯一源差异是实际 client 副本在同一 live Pending 上保留 `invalidRequest` 的原优先级：`worker/attempt-054/check-source-delta.log`。未据此把编译结果当作行为测试。

## 实现要点

1. **启动前同一基线。** 以原 `RepositoryBindingProvider.makeFixture(role: .controller, ...)` 在原 owned spawn 前建立 whole-document baseline；同一 provider 和观察贯穿该 generation，不重新 acquire 或 rebaseline。复用真实 `KernelIdentityBridge`、原 `FoundationProcessSpawner().spawnOwned(...)` 返回的 `OwnedRunnerProcess` 与 fresh birth；controller 不取得 runner 的 `ProfileLock`，也不从 PID 文件或 wire 获取处置权限。
2. **单一 reader 与 writer。** 原独占 `ReaderLease` 供 hello/ready 使用，并在实际 peer 与同一 repository baseline 检查后一次移交真实 client 原 reader loop；runner/controller 是封闭的具体 owner，admission 在派生 server 词法文件中封装并一次使用。继续复用原 channel 的单一 writeQueue、head/retry receipt 和单一物理 `Darwin.write` 路径，不叠加第二个 client、reader、writer 或授权机制。wire `ready` 仅用于关联，**不是 GUI 或输入授权**。
3. **请求尝试与截止时间。** 沿原 client Pending、generation、cancellation、sent-ID 和错误/副作用映射；`sentIDs.insert` 与 `attempted = true` 在新增 mint 的第一个 await 之前，未进入 send 尝试的队列请求仍按原未尝试语义处理。controller admission 由具体 context 向已附着真实 client 读取同一 Pending 的编码与 caller deadline，head 和 retry 时复核 Pending、repository、真实 peer 与原 owner/birth。controller reservation backpressure 的健康、未入队例外与 runner 原关闭路径区分；不因该分支宣称完整 backpressure 竞态矩阵已覆盖。
4. **固定预算。** 原 caller 绝对截止时间在登记时捕获、不续期；controller 检查同时受原 fixture 45 秒外层寿命约束，不将 runner 默认 3 秒帧上限暗中加到较长的 controller caller timeout。runner 017 原 3 秒/45 秒默认与 bridge/C 的 duration 转换保持原路径。45 秒自然寿命的完整耗时试验未覆盖，见下文。
5. **单一终止记录与清理。** client stop 在结算 Pending 之前同步操作同一 `FixtureRevocation` 并关闭 channel；已由 context 保存的首个真实 C 错误不被后到 client 错误替换。deinit 同步撤销并安排只捕获 context 的 actor 资源清理。`safeClose` 保留已有的幂等防御性 revoke 和有序资源释放，不依赖异步清理来提供 client stop 的同步撤销。清理仅使用原 retained owner 与 fresh 原 birth 证明；没有引入 PID 扫描或新处置权限。
6. **reply 与 timer。** reply 解码/关联及 action/target 校验保留 schema-invalid 优先于取消/超时的原语义；实际 context full check 的 await 前后重查同一 Pending 的 id/generation、action、取消、deadline、admission、固定 cutoff、channel 和原 revocation，最后只提交一次。Pending 移除时同时结算该 Pending 的 admission timer，避免已提交 reply 后仅因 send continuation 尚未恢复而留下旧 writer timer。若 timer callback 已先取得锁并开始撤销，不能据此推断全局原子性。
7. **controller 独立 inbound 证据。** 测试先让真实 runner 写完有效 reply、完成 post-write，并观察下一次真实 reader 已 admit；client 已收到并暂停，之后才修改真实 repository 并释放检查。first-terminal 记录为 `controller-inbound` / `repositoryChanged`，不是把 runner 先拒绝当作 controller 证明。调度钩子只暂停、观察或限制真实物理分块，不替代鉴权结果。

## 主 agent 最终 052 独立验证

聚合来源：`main-review/all-final052-runtime-summary.json` 与 `main-review/all-final052-runtime-results.json`。结果为 **170 次最终源 CLI runtime 调用**：85 normal、85 ASan；全部符合各自预期断言，最终 170 次的精确 source/test 输入 SHA 均保持不变。这是调用次数，**不是 170 个互不重复 case，也不是 GUI 或业务成功数**。

| 主方分组 | runtime 调用 |
| --- | ---: |
| invalid-role | 2 |
| pure-no-hooks | 2 |
| controller34 | 24 |
| controller1 | 24 |
| controller2 | 16 |
| repeat | 16 |
| worker-oracle-mainReplay | 12 |
| runner 017 回归 | 74 |
| **合计** | **170** |

runner 74 次为原 runner 回归，不能单独证明 controller 新机制；pure-no-hooks 为无测试钩子的 CLI 路径，不能外推生产/GUI。负向断言中父 fixture 以 0 退出仅表示该断言达到预期，并非业务执行成功。实际子进程按 case 可能以 78 退出，例如测试不发送原 driver 所期待的两次完整请求时；日志、预期和 owner 退出需按对应 case 判断。

### 独立旧源反例与结构检查——不计入 170

- 主方另外执行 **4 次实际 C 旧源反例**：025 旧 timer normal/ASan 各 1 次、047 旧 invalid-role 优先级 normal/ASan 各 1 次，预期 exit 78。025 反映已提交回复后旧 writer timer 可误撤销；047 反映原 valid(reply) 应优先的错误角色回复在 deadline 后被错误重标。它们不是缺 API 或编译失败，不加入 170，也不声称编写/运行顺序构成 chronological TDD。
- 最终 private API 编译结构检查共 **4 项**：正向 1 项、负向 3 项，期望结构均一致；这是封装可见性的编译证据，不是 runtime 身份证明或行为 RED，不计入 170。见 `main-review/private-api-final052/summary.json`。
- 先前 intermediate 结果和 worker `attempt-049` 的 20 次（14 个新候选预期通过、6 个旧对照预期反例）独立保留，**不再叠加到最终 170**。此前 worker `attempt-035` 的 timeout-send 不符合当时预期也保留；后续新编号修复与对照不能倒填成当时通过。

## 保留的失败、纠正与历史事件

- 三项历史违规/事件保持记录、未被绿测抹除：tmp-glob／拒绝命令绕过、只读 process scan、compiler-cache 73-file 事件。具体边界和未解决状态见 `contract.md`；本记录不把它们表述为已解决。
- 主方 `matrix-syntax-026` 是独立测试 Swift 语法/typecheck 失败：`offset()!=nil` 被解析产生歧义；原输入/日志保留，新 V2 使用明确空格纠正。该事件不改功能源、没有 runtime，**不是行为 RED**。见 `main-review/matrix-syntax-failure.json`。
- 主方在 V2 runtime 前根据实际 runner 路径纠正 V3 收尾 oracle：partial/truncated denial 下，主 child wrapper 断言 handlers 0/status 1 后正常 exit 0；它不同于原未修改 V1 driver 期待两个 handlers 时的 exit 78。V3 额外要求明确 handlers/status marker；原 V2 编译输入及未运行批次保留。见 `main-review/matrix-v3-oracle-ruling.json`。
- worker 的 `attempt-012` 测试 enum 参数标签编译失败和 `attempt-050` 只读完整性脚本语法失败也保留，后续新编号更正；均不是行为 RED。早期探索性命令未全部另存独立持久日志，不能声称所有历史命令均具备完整外置日志。

## 未覆盖与禁止外推

本单元尚未穷尽：controller full-byte-budget backpressure 及 terminal race、4096 sent-ID/控制预留上限、全部 foreign/cross-generation/invalid-ready/cleanup 取消矩阵、真实 OS EINTR 和 OS 阻塞、完整 45 秒自然寿命。有限调度测试不是这些场景的全覆盖，也不能证明 hostile same-UID 环境下的全局原子性、泄漏自由或 quiescence。OS/文件系统检查与读写之间仍非事务性原子操作。

本单元没有可用的 productionComposition；没有运行实际 GUI、AppKit/WebKit 对象、LaunchServices、全局输入或 VM。既有安装/旧 candidate 仅作只读完整性审计，未写入、运行、重签或改权限；未操作真实 Profile/用户会话，未调用本轮 TCC/LA/Keychain 凭据链；未发布、部署、提交或推送。`fullP1`、`G1`、`G5`、`input`、`shipping`、`liveAdapter`、`GUIExecutionAuthorized`、`manualGrant`、`GUIReady`、`ready`、`armed` 均为 **false**：这些是政策/验收门禁，不代表操作系统授权数据库状态。本文只记录离线 fixture 的范围与证据，等待主 agent 最终审定。
