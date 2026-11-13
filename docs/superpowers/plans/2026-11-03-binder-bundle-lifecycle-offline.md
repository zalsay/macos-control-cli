# Binder AppBundle 与生命周期离线实现计划及执行状态

**目标：** 在旧代码和 guard 约束下，将真实 Bundle 全部资源与实际 owned/observed headless 进程绑定。  
**设计：** `docs/superpowers/specs/2026-11-03-binder-bundle-lifecycle-offline-design.md`。  
**职责：** Terra worker 实现并提供证据；主 agent 是唯一设计/代码 review 和独立验收者。  
**当前状态：** 本轮离线实现与 worker 聚焦验证已交接；主 agent 报告独立 Task 1 共 24 次和 Task 2/3 共 29 次程序断言满足。主源码审查已由 `main-code-review.json` 接受有界离线源码及 53 次独立程序验证；不能从本计划勾选推出整体 P1/GUI 完成。最终保全门禁为 `.build/automation-binder-bundle-20261103/main-final-audit.json`，本计划不替代 audit。

## 全局约束

- 仅 staged `.build/automation-binder-bundle-20261103/worker/` 代码；复用原 diagnostic collector、Control/Transport、七 Core、原 spawner、clock 和 owned cleanup。不得以另一套 verifier/transport/executor 替换。
- actual EntryCandidate 仅私有副本静态对照 baseline，原件和副本不执行、不重签；原 `/Volumes` 775 不改。独立 tiny/Swift CLI fixture 限新 0700 HOME 根构造期签名，先签再 pin，不对已 pin 样本重签。
- 独立固定 namespace、BID/exe、完整资源 seal、静态 code 与真实 self/peer/owner/parent 一起决定 actor 私有 generation；普通 inventory 观测不是授权。
- 原 3 秒 frame、45 秒 lifetime、role、握手、half-close 和仅原 owner + fresh metadata 清理不放宽；资源失效不能禁止纯 metadata cleanup。失败、取消和重绑不恢复。
- 不触及 AppKit/WebKit、真实 GUI/window/Space/profile/grant、AppleEvent、TCC、全局输入、注册/安装或旧签名；不造 GGContext、不调用 manual/seal/arm。所有 GUI/input/shipping/liveAdapter/整体 P1 门禁保持 false。

## Task 1 — 目录清单、实例 pin 与签名

- [x] 建立目录 FD、no-follow 全量 namespace 观测，使用旧 `bi_snapshot` 文件采集；版本域分离的 content digest 与 instance metadata 分离。保留 readdir 独立 offset、errno、FD 释放和 CLOEXEC 约束。
- [x] 资源、文件、目录、路径、数量/深度/文件及总量限制；xattr/ACL 纳入实例，Bundle metadata 限 4 MiB，沿原 deadline 逐操作检查；path/BID/leaf 有界读取。严格签名检查三项 SDK flags，plist bytes 与 snapshot 匹配，expected BID/executable 与主 code pin 比对。
- [x] worker 的 C normal/ASan+UBSan 聚焦测试和 candidate 私有静态比对已记录；主 agent 的 **24 次独立程序运行**另列于 `main-review/task1-independent-results.json`，包含 12 normal、12 ASan+UBSan。
- [x] 主 agent 已生成本轮 `main-code-review.json`，只接受有界离线 Bundle + 进程生命周期范围。
- 最终保全门禁以本轮 `main-final-audit.json` 为准，本计划不替代 audit。

## Task 2 — 真正 Bundle fixture 与桥接

- [x] 新 0700 私有根、独立 offline BID、构造期本地签名和 receipt；controller/endpoint 直接运行同一个签名 `.app/Contents/MacOS/BinderProbe`，不经 LS。旧 candidate 仅静态读取；不修改主 agent 私有样本或旧 App。
- [x] staged bridge 从 kernel self 路径派生 Bundle，拒绝旧布局；private resource factory 固定完整 expected tree，进行严格签名与完整前后重验；动态 self/peer 仍使用原 collector。
- [x] 实际初始 extra empty dir 在 native strict seal 有效的情况下被 expected namespace 拒绝；主静态 candidate/initial-extra normal 与 ASan 各 1 次，均记为静态检查，不是 GUI 或进程运行。
- [ ] 原计划“旧 bridge 对新 Bundle 的独立行为 RED”无单独已交接证据，不补称已完成。最初缺 `BundleInventory.h` 的编译失败仅为接口 RED，不是行为 RED。

## Task 3 — 生命周期、取消与原 owner 清理

- [x] 在 staged `AuthenticatedConnection` 关联一次性私有 generation，rebind、stale、资源/进程变化、取消、退出或迟到不能恢复；连接双方依然按原方向和协议工作。observed actual parent 不获得 cleanup 权。
- [x] 真实 Bundle 子进程的资源和空目录负例由 endpoint 真正收 ACK 后经 test-only 单字节 stdout 管道通知 parent，再等待有界 stall；parent 观察后才变更。两类负例均 sticky close，原 owner 通过 fresh metadata 后 TERM；empty dir 的 native strict verify 仍为 0。
- [x] 修复 factory 在 C 成功返回后、Swift post-deadline/cancellation 抛错前遗漏释放：冻结旧版真实 inventory 取消 RED 为 FD 3→4，修复版 normal/ASan 均 3→3；test-only release barrier 有界，超时测试预期退出 1。
- [x] no-proof 不终止未证明的进程，记录 `cleanup_unconfirmed`；peer exit、cancel、rebind、stale 和 role 负例保留独立日志。旧资源负例先由 self code 检查返回 `BI_IO`，不改写为 Bundle `BI_CHANGED`。

## Task 4 — 分开计数、审查和交接

- [x] worker 最终真实 packaged CLI 正常对照 normal 3 次 + Swift ASan 1 次；资源、空目录等负例及对应 normal/ASan 证据与 earlier 尝试分开。最终正常日志仅打印比较后的布尔阶段，不逐帧输出 kernel 详细字段；旧详细调试日志保持原样。
- [x] 主独立 `main-review/integration-results.json` 为 **29 次程序运行**：20 次真实 packaged CLI、4 次静态 candidate/initial-extra、2 次 factory-cancel green、1 次 release-timeout 负例、1 次冻结 leaky RED、1 次 outside-layout 拒绝。与主 Task 1 的 24 次合计 53 次，不能和 worker 次数混加。正常会话退出 0；阴性会话退出 78；预期 RED/timeout 退出 1 不是业务成功。
- [x] 主最初 normal 的 oracle 使用了错误布尔 label：实际执行退出 0，原断言 false；主以**同一原始输出**纠正断言，没有重跑该程序。保留 `integration-first-oracle-failure.json` 与 `integration-oracle-correction.json`，不能声称所有尝试均通过。
- [x] 主 agent 已生成本轮 `main-code-review.json`；不授权真实 GUI。
- 本轮最终保全以 `main-final-audit.json` 为准；此计划、离线结果和 audit 路径均不赋予后续真实阶段授权。

## RED 与证据纪律

metadata deadline 的真实回归以受控延迟包裹真实属性调用：旧实现 deadline 后继续 4 次 get，修复后停止并准确 expired；factory cancellation 的 FD 3→4 是实际行为 RED。接口缺失、测试 oracle 缺 marker 或编译错误分别如实标注，不冒充生产行为 RED。旧历史 `BI_CHANGED` 原因未确定；资源 mutation 的 self/`BI_IO` 首拒绝和原始日志不被后续结果覆盖。详细路径、命令、退出分类和边界在 `docs/verification/2026-11-03-binder-bundle-lifecycle-offline.md`。

## 历史与当前版本清单

`worker/task2-task3-SHA256SUMS` 是最终 ACK 观察和 test-only timeout 修订之前的历史版本清单，不应直接以当前 staged 路径验证。历史两份源码已恢复到 `worker/historical-source-archive-20261103/`，按 `path-map.json` 路径映射验证旧清单 10/10 项 SHA；当前最终源码则以 `worker/final-source-SHA256SUMS` 单列。旧清单、旧日志和当前源码均未为归档而改写。
