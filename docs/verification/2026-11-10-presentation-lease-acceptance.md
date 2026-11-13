# 2026-11-10：非激活启动与 presentation lease 验收

本轮已完成一次真实视频号环境的 connect → state → observe → release → daemon stop，无页面输入、导航或模型调用。主 agent 已核对回执并目视 `page.png`，确认是真实已登录的视频号主页。用户确认北京时间（UTC+8）13:51:34–49 未发现干扰；保留窗口的人工手动浏览暂未检查，`manualBrowserHumanCheck=pending`。

## 修复与验证边界

- 启动呈现路径：CLI 普通 launch 传播 `nonActivatingPresentation`，Runner 以 accessory 启动；Manager 使用既有 `--show-manager-without-activation` 与 `activates=false`。不主动激活窗口；人工启动路径保留原语义。
- 已证实的 lease 根因：独立无窗口 AppKit 探针首次设置 accessory 返回 true，再次设置同 policy 返回 false，但实际 policy 仍 accessory、active=false、windows=0。原 acquire/restore 无条件要求 setter 返回 true，因而拒绝已处于 accessory 的 quiet Runner。
- 最小修复：仅当读取 policy 不等于目标时调用 setter；真实转换返回 false 仍拒绝。最终 policy、inactive/key/main、manual/window、lease 与 input-drained 检查均保留，不以切到 regular 抢前台解决。
- 定向 red/green：新增已有 accessory 且 setter 拒绝的用例，修复前失败；修复后共 6 项 lease 测试通过。另新增“setter 返回 false 即使 policy 已改变仍拒绝”，原转换/恢复失败、未 drain、外来 lease 与激活拒绝测试保留。
- 主 agent 独立核验本候选 122 项 source、11 pins、两层 strict 签名及 stage 原 C 探针通过；相对前包生产源仅 `BrowserWindowController.swift` 的已审 lease 修复。本记录不替代源码 review。

## 本轮实际结果

`controlReleased` 中 `inputReleased`、`artifactsCleaned`、`browserRetained`、`manualInteractionEnabled` 均为 true；与本轮 state 的 exact target 一致：

| 字段 | UUID |
| --- | --- |
| profileID | 9080635F-0A64-4ECC-9969-58C9618B5072 |
| runnerInstanceID | 2E964460-BD9A-42BA-9067-5F08431069E7 |
| windowID | 4E451C0A-ECB1-42FE-A315-16FAD7696C0C |
| pageID | 31E09334-E68C-46EE-91E6-EBD2792E5881 |

原临时截图及 artifact 父目录已删除，证据副本保留。本轮专用 daemon 与 socket 已不存在；同一 Manager/Runner 窗口保留。release 回执是释放证明，daemon/socket 消失仅为额外终态观察。

北京时间（UTC+8）13:51:34–49，30 次前台采样均为 `com.zalsay.copis`，用户已确认该时段未发现干扰。用户尚未检查保留窗口的手动浏览，`manualBrowserHumanCheck=pending`；程序回执 `manualInteractionEnabled=true` 不代替人工验证。此前北京时间（UTC+8）13:42:33–40 的“未发现干扰”反馈仍仅适用于上一轮。

## 历史失败仍保留

上一轮 connect 到 page_factory 返回 INTERACTION_REQUIRED，daemon stop 返回 SESSION_BUSY（openingUncertain 门禁）。未重试 stop、未清 uncertain。主审核准后，核验独占 runtime、精确 argv、uid/出生时间及动态/磁盘签名，以 kqueue NOTE_EXIT 监听并仅一次 SIGTERM 做专用 daemon 资源处置；退出已确认，旧 socket 未删除。创建时未保存 birth/CDHash 快照，当前出生时间仅与原创建区间及进程记录关联。该退出 **不是旧轮 release/cleanup 证明**。

更早的 RUNNER_EXITED/root 注册拒绝点本轮未复现，具体根因仍未证实；本轮成功不能证明原始失败必然已根治。此轮未验收输入点击、业务变更或新一轮重连，不扩大验收范围。

## 精确证据位置

以下路径均相对仓库根 `/Volumes/RC500/dev/safarier`；它们是本轮证据位置，不是 CLI 身份或安装路径门禁。

- lease 探针、修复前快照/增量及 red-green 日志：`.build/presentation-idempotence-a6391f46c96c4a0c83d1b7b13e242c5d/`，其中 `probe.stdout`、`test-before.log`、`test-after.log`、`incremental.patch`、`delivery.json`。
- 候选：`.build/automation-bound-control-integration-20261104/formal-test-app-20261106-001/packaging/attempt-20261110-134656-5055328ef93447beb6bbeaa686495be3/`，含 `source-before.json`、`source-after.json`、`candidate-sha256.json`、`receipt.json`。
- 构建及旧 daemon 资源处置：`.build/presentation-release-4911f71be20f466ea656a281bef8641a/`，含 `build.log`、`daemon-identity.json`、`daemon-running.json`、`steps.json`（旧轮原步骤）、`failure-daemon-stop.stdout`、`daemon-termination-result.json`。
- 本轮独立包审与 driver：上述目录下 `gui-round/main-review.json`、`candidate-binding.json`、`final-ready.json`。
- 本轮完整运行证据：上述目录下 `gui-round/evidence/`，含 `steps.json`、`connect.stdout`、`state.stdout`、`observe.stdout`、`page.png`、`screenshot-copy.json`、`release.stdout`、`release-proof.json`、`terminal-resources.json`、`final-apps.stdout`、`foreground-and-process.jsonl`、`main-acceptance.json`、`summary.json`。
