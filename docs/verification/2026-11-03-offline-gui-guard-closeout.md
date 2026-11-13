# 2026-11-03 离线 GUI 护栏收口材料

## 结论与授权

离线 C 核心与 Foundation/NSObject 测试替身已实现并由原主 agent 审查验证；本轮只确认冻结材料未变、重新构建运行离线 CLI 并同步文档，**不构成新的代码审查或最终主审结论**。完整 P1、live Binding 和真实 GUI 验收均 blocked；G1、G5、shipping、input、liveAdapter 和真实 GUI 授权均为 false。2026-11-03 用户仅授权 offlineDesign/test 的文档与离线审计，不新增功能或放宽门禁。

## 原始与本轮证据

- 原始证据根 `.build/automation-gui-routing-guard-20261102/`：`status.json`、`main-code-review.json`、`main-review/*independent.log`、`main-review/no-gui-linkage-check.json`、各组件 HANDOFF 和 SHA256-SOURCES。原主审记录修复了拒绝后状态可复用、Manager 窗口/策略、前台状态、时限和身份数值范围、在途 trip 后错误返回 YES、调用中时钟未推进等问题；修复前失败与 RED（包括 `main-review/repro-before.log`、`adapter-repro-before.log`、各 `review-red.log`）原样保留。该陈述引用原审记录，不是本轮复审。
- 旧 `main-code-review.json` 的 `runtimeExecuted=false` 存在歧义：离线 CLI 实际执行过，真实 GUI 未执行。本轮明确 `offlineCLIExecuted=true`、`realGuiExecuted=false`；原记录未改。
- 主 agent 独立重建和关键回归证据：`.build/automation-gui-routing-closeout-20261103/main-regression-results.json`、`.build/automation-gui-routing-closeout-20261103/main-independent-regressions.log`；normal 与 ASan/UBSan 的 core/adapter 关键回归通过，仍仅为离线 CLI 证据。
- 2026-11-03 执行证据：`.build/automation-gui-routing-closeout-20261103/worker-audit.json`、`worker-tests.log`、`worker-build/`；原始 20261102 路径是证据根，不代表本轮重验发生于 11 月 2 日。

## 本轮验证

1. 构建前，两份 SHA256-SOURCES 检查通过；全部主审 frozenSources 与当前及本轮 before.json 一致。构建后冻结哈希及两份清单再次一致。文档同步前的快照中，before.json 所列文件、特殊资产、分支、HEAD、index flags 和 sibling 状态对比一致；文档同步后，原有设计与计划文档已修改，收口报告为新增，不应称全部基线文件未变。文档完成后的源码及特殊资产另行核对，结果见 worker-audit。命令与退出状态见 worker log/audit。
2. 从原源码绝对路径在新目录编译 C core 和 Objective-C fixture，各 normal 与 ASan/UBSan 构建及完整离线 CLI 运行均退出 0；adapter 两种构建各运行 `trip`、`expire`、`nested`、`rollback` 均退出 0。编译器版本、命令、stdout、stderr 与状态均保留在 log/audit；未执行旧构建脚本。
3. normal 二进制 `otool -L` 与 `nm -u` 清单已留存：core 直接链接 libSystem；adapter 直接链接 Foundation、CoreFoundation、libobjc、libSystem。清单中无直接 AppKit/WebKit 库或真实窗口事件、权限 API、进程启动/终止导入。仅检查直接依赖和未定义符号，**不声称所有传递依赖无 GUI**。

## 未证明与限制

测试替身不是 GUIRunner；模拟 context/observation 不是内核身份认证，单状态 grant 不是真实持久授权。真实 Binder、控制通道、内核身份、对象真实生命周期、ready/armed、前台和 Space、真实 GUI 关闭及人工清理均未验证；policy 1/2 不支持，Manager accessory 初始化存在缺口。外部并发修改 IMP 无原子 CAS；ObjC/Foundation sanitizer 不能提供完整泄漏证明；超时或 trip 不能撤销已经发生的 effect。

本轮未运行真实 App/GUI、AppleEvent、权限 API、osascript、UI 注册、VM 或全局输入；未安装、提交、推送或发布。原 readiness 模板及旧证据均未修改。主 agent 最终结论见 `.build/automation-gui-routing-closeout-20261103/main-final-audit.json`；worker 材料不替代该记录。
