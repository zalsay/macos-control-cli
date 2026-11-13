# Binder AppBundle 资源与生命周期离线验证记录

日期：2026-11-03；分支 `mcc-safarier`；基线 HEAD `2f32d21248deaffd8c8c1152a39912aa46350c7e`。实现只在 `.build/automation-binder-bundle-20261103/worker/`，未接正式产品。主 agent 是唯一代码审查者；其 Task 1 和 Task 2/3 独立程序结果分列如下。`main-code-review.json` 记录主 agent 已接受有界离线 Bundle + 进程生命周期源码及 53 次独立程序验证；结果如下分列。最终保全门禁以 `.build/automation-binder-bundle-20261103/main-final-audit.json` 为准，本报告不替代 audit。

## 范围与制品

- actual EntryCandidate 原件及私有副本仅静态检查，**均未执行、未重签**。原 `/Volumes/RC500` 775 祖先按原策略拒绝；私有 0700 HOME 副本与 `candidate-static-baseline.json` 的 16 条 namespace、9 个文件 SHA 匹配，文件合计 43,625,277 bytes。static inspector 在 candidate Bundle 外。
- Task 1 的 tiny C CLI fixture 与 Task 2/3 的 Swift headless CLI fixture 是新根内新构建的不同测试制品；构造期本地 ad-hoc 签名、记录签名命令/根 dev+ino/主映像 SHA 后才 pin。无对旧 App、candidate、旧根或已 pin fixture 变更后重签；签名不构成 Developer ID、公证或部署。
- 实际认证正例直接运行新签 `.app/Contents/MacOS/BinderProbe`；controller 用原 FoundationProcessSpawner 启动相同内包映像作为 endpoint，依旧使用原 anonymous socketpair、collector、role、parser、时限和 cleanup。不是拿 Bundle 旁无关 CLI 冒充 Bundle 进程，也没有 LS/open/NSWorkspace 启动。
- `bb_inventory` 只是观测；private factory 对照独立 expected namespace 后做 strict whole-Bundle seal、plist 与主映像 pin 的完整前后复核，连接绑定还要求实际 kernel self/peer 与 retained owner/actual parent 一致。actor generation 是私有生命周期状态，不是 wire、nonce 或清单自证明。

## worker 结果（不得与主独立次数相加）

| worker 范围 | 证据与限制 |
| --- | --- |
| Task 1 C 与静态 candidate | `deadline-final-*` 日志记录 normal 和 ASan+UBSan 的重复扫描、链接/特殊文件、数量/大小/深度边界、metadata deadline/预算和 guard-page 参数；`deadline-final-candidate.log`、`deadline-final-candidate-baseline.log` 为静态 candidate 检查。 |
| 真实签名 Bundle 正常 | `batch8-normal-{1,2,3}.log`、`batch8-asan-1.log` 为 worker 的 normal 3 + Swift ASan 1；此批次早于最终 ACK 观察测试修订，只用于记录该版本 worker 对照，不能冒充修订后的主独立矩阵。原已记录的详细 kernel 调试日志保留，新版正常日志是比较结果布尔值。 |
| 最终 ACK 观察后的资源负例 | `final-{resource,resourceasan,empty,emptyasan}-run.log`：endpoint 真实收到并提交 ACK 后用 test-only stdout 单字节通知，parent 有界等到通知后才变更；每项预期退出 78，后续 closed，原 owner fresh metadata proof 后请求 TERM，child signal 15。对应 `*-native.log` 中 empty strict verify 退出 0，resource seal 已失效退出 1。 |
| Bind 与生命周期 | `batch8-{rebind,stale,role,noproof}-run.log`，`batch9-{peerexit,cancel,rebindasan,staleasan,roleasan,noproofasan}-run.log` 分别记录受控场景。无证明分支为 `cleanup_unconfirmed`、不请求 TERM，随后另记录 retained child 自然退出；不可把退出 78 视为业务成功。 |
| Factory 释放与有界观察 | `cancel-factory-red.log` 实际 C inventory 成功后取消，冻结旧测试版 FD 3→4；`final-cancel-factory-{normal,asan}.log` 在真实 C inventory 成功后取消，FD 均 3→3，程序退出 0 代表断言满足。`final-cancel-factory-timeout.log` 对 test-only release barrier 故意不放行，预期退出 1 并记录 release-timeout，不伪造成功 pin。 |

`final-ackbarrier-results.json` 是 worker 定向汇总，`final-source-SHA256SUMS`、`staged/final-bridge.diff`、`staged/final-harness.diff` 是交接快照；`main-review-freeze-SHA256SUMS` 为此前冻结版本，后经授权只改 staged FullHarness 与 cancellation test，差异记录 `final-freeze-comparison.log`。早期 batch6 详细 self/peer 调试字段仍为历史证据，不得覆盖或与 final 布尔日志混称同一批。


### 历史清单与 final 版本的路径映射

`worker/task2-task3-SHA256SUMS` 固定的是最后 ACK 观察和 test-only release timeout 修订前的历史版本；其 `staged/FullHarness.swift` 和 `staged/BundleFactoryCancellationTests.swift` 两项不再对应当前文件，**不能称旧清单直接校验当前源通过**。主发现该可追溯性问题后，worker 在新的 `worker/historical-source-archive-20261103/` 中恢复了旧版两文件：前者由冻结 lifecycle `FullHarness.swift` 与旧 `staged/harness.diff` 重建，后者恢复为有界 wait 修订前的测试版。`path-map.json` 把两条旧路径映射到归档，其他旧路径仍指原位置；逐项与旧清单比较 **10/10 SHA 一致**，映射后的清单为 `resolved-SHA256SUMS`。旧 manifest、旧日志和当前源均未为归档而改写。当前最终源码单独以 `worker/final-source-SHA256SUMS` 和 `staged/final-*.diff` 记录；该问题是历史版本可追溯性，不是新的身份失败，也没有通过重跑洗绿。

## 保留的红测、失败及定位

1. `inventory-api-red.log` 是缺少新头/API 的**编译** RED；不能说它证明旧实现运行时行为错误。`expected-namespace-red.log` 同样是新接口编译 RED。`final-ackbarrier-red.log` 只证明旧日志缺少新的调度观察标记，不是生产安全故障的行为复现。
2. `metadata-red.log` 通过测试包装在真实属性列表调用后插入受控延迟；旧 metadata 路径超时后仍执行 4 次属性 get。修复沿同一绝对 deadline 在 list/get/hash/ACL 前后检查并设 4 MiB Bundle 级 metadata 上限；`deadline-final-MetadataDeadlineTests-{normal,sanitize}.log` 为其后验证。初版另因正常 `com.apple.provenance` xattr 被误拒，原失败与 `acl-diagnostic.log` 保留，后将 xattr/ACL 纳入 instance pin，未省略属性。
3. `cancel-factory-red.log` 的冻结旧版在真实 `bb_inventory` 成功后取消，FD 3→4；修复将 cleanup defer 注册在第一次 C 调用前，并仅在最终私有 pin 接管时转移所有权。红测和修复后的 3→3 分开记录。
4. worker 旧 `batch2-resource-run.log` 的故意 sealed-resource 变更先触发原 self 动态 code 检查 `BI_IO`，不是 Bundle `BI_CHANGED`。`batch2-resource-diagnostic-native.log` / `batch2-resource-diagnostic-inventory.log` 保留 native seal 已失效的只读诊断；后来测试明确记录首拒绝阶段，没有放宽身份判据。空目录负例则在 native seal 仍有效时由 Bundle 清单 `BI_CHANGED` 拒绝。
5. worker 最终 ACK 观察测试以 `final-ackbarrier-red.log` 保留旧版本缺标记；开发过程中 Swift 条件编译导致 `session-batch5-empty-build.log` 的 harness 编译错误，已留存并用新命名版本修复。先前调试日志不改写成最终布尔日志。
6. 历史 lifecycle `final4-overlap-asan-1.log` 的 `BI_CHANGED` 精确原因仍未证明；本轮资源 mutation 的首拒绝和其他成功批次不能反推或覆盖历史原因。

## 主 agent 独立结果（与 worker 分列）

### Task 1：24 次

`main-review/task1-independent-results.json` 记录 **12 normal + 12 ASan/UBSan**，共 24 次程序运行，断言均满足。覆盖 repeated scan/空目录、边界、identity/resource/root/replace/remove/xattr、metadata deadline、guard-page 输入、真实 candidate 静态 expected 16/9 及初始 extra-empty 拒绝。主 agent 对 candidate 独立计算的 canonical content digest 为 `0e68816048a5ee9ecda83ba4fc87671535cc5bf447b8ef021c934e13c60ac424`，与 collector normal/ASan 结果一致；不把静态 candidate 冒充进程执行证据。

### Task 2/3：29 次

`main-review/integration-results.json` 记录 **29 次程序运行断言满足**：

| 类别 | 次数与退出语义 |
| --- | --- |
| 真实 packaged CLI | 20 次：正常 normal 3 + Swift ASan 1，均退出 0；resource、empty、rebind、stale、role、noproof、peerexit、cancel 各 normal 1 + ASan 1，阴性会话按预期退出 78。 |
| 静态检查 | candidate 与 initial-extra 各 normal 1 + ASan 1，共 4 次；static probe 退出 0 是断言满足，不是 candidate 业务执行。 |
| Factory cancellation | green normal + ASan 共 2 次退出 0；test-only release-timeout 负例 1 次预期退出 1；冻结 leaky RED 1 次预期退出 1。 |
| Outside layout | 实际 kernel 可执行布局在 Bundle 外的 1 次预期退出 78。 |

独立资源/空目录负例均先观察真实 endpoint ACK、再修改、随后 sticky close，并以 fresh metadata proof 对原 owner 请求 TERM，记录 signal 15；empty 的 native strict verify 仍为 0。正常退出、预期 78、预期 RED/timeout 1 和 signal 15 各有不同含义，不可汇总为 29 次业务成功。加上 Task 1 的 24 次，共 **53 次独立程序运行记录**，不包含 worker 的运行次数。

主 agent 最初一次 normal 程序**实际退出 0 且输出正确**，但主测试 oracle 拼错预期布尔 label，原断言为 false，保存在 `main-review/integration-first-oracle-failure.json`。主以同一次未修改的原始输出重新判定，不重跑该程序；修正记录为 `main-review/integration-oracle-correction.json`，同一执行作为 `integration-results.json` 中的正常第 1 次。由此不能说所有历史尝试都通过，也不能将这次 oracle 错误表述为 runtime identity 失败。


### 主独立辅助检查与源码边界

- `main-code-review.json` 只接受有界离线 Bundle 与进程生命周期绑定；不代表生产 `Sources` 已接线，也不授权 GUI 或真实产品运行。
- `main-review/integration-no-gui-audit.json` 对 normal image 的直接依赖、未定义符号和源码扫描未发现 AppKit/WebKit、输入、权限、注册或 listener 命中；normal 构建未包含 `ReadSchedule`、factory test hook 或测试 generation 方法。主 agent 记录 `_bi_capture_peer`、`_bi_snapshot`、`_bb_inventory` 各一个。此检查不穷尽传递依赖，不等于 GUI 运行验收。
- `main-review/cleanup-metadata-preservation.json` 记录 `ownedChildMetadata` 和 `actualParentMetadata` 与旧版字节一致；资源验证失败后的清理仍使用原 owner/fresh metadata，不因 Bundle seal 失效而阻断采集。
- `main-review/bundle-analysis.json` 的 C `clang --analyze` 退出 0、诊断 0；该静态分析不是形式化证明。`integration-results.json` 记载 29 次独立集成运行的 HOME metadata 均未变化。

## 最终限制

本记录只覆盖受控 headless 代码/资源和进程成员关系及限定时序；不是 GUI 注册、AppKit/window/Space/profile、前台/人工 grant、input 或真实产品路由的验收。`fullP1`、G1、G5、input、shipping、liveAdapter、GUIReady/ready/armed、GUIExecutionAuthorized 和人工 grant 全部保持 false。没有证明防恶意同 UID、主动 FD 转交、原子 FD-exec、瞬态 TOCTOU 或中断阻塞 OS 调用。主正式 code review 已完成，最终保全门禁以本轮 `main-final-audit.json` 为准，本报告不替代 audit；任何后续真实阶段需要单独授权。
