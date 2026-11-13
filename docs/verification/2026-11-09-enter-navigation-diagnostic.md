# Enter 导航关联诊断：单轮 Selenium 实测

日期：2026-11-09。范围为内测 candidate、独立 ephemeral profile 和 Selenium 测试表单的单轮验证，不代表任意站点、发布或部署验收。主 agent 独立审查五文件源码、candidate/副本及本轮原始证据和截图。

本轮仅为定位此前 `home-text-003` 的 Enter `INDETERMINATE_RESULT` 增加 candidate-only 固定阶段、非授权 request UUID、单调时间及错误分类日志；未改协议、预算、身份、输入或清理语义。改动文件为 `ControlAppleEventClient.swift`、`ControlDaemon.swift`、`AutomationManager.swift`、`RunnerAutomationController.swift`、`AutomationRunnerServer.swift`；页面沿用已有 `NAV_DIAG`。原副本与 SHA 在 `.build/navigation-diagnostics-91f85e45303c44ce827a993d45366e7e/before-sha256.json`。candidate 与 normal 配置 `swift build --product Safarier` 均 exit 0。

testing stage 为 `.build/automation-bound-control-integration-20261104/formal-test-app-20261106-001/packaging/attempt-20261109-155257-61b71d99d9d6402788ddfef57b9edc30`：109 项源码 before=after=current，九项 stage 和 home 副本 pin 匹配，namespace、metadata、resources 与 Manager/Runner 两层 strict 签名通过；见 `.build/navigation-diagnostics-91f85e45303c44ce827a993d45366e7e/package-inventory.json` 和 `prepared-instance.json`。主已独立核验。测试 App 为 `/Users/yingzhang/sfr-nav-c90684cd24ec47d082c2fb773ebca299/Safarier.app`，workspace 同目录 `workspace`，profile `45056787-1166-41f8-9adc-9fa9c65e6ff3`。

## 单轮结果

时间 UTC（美东当日 UTC-5），原始文件均在 `.build/navigation-diagnostics-91f85e45303c44ce827a993d45366e7e/gui-driver/evidence/`。08:02:44 connect；Selenium 表单输入区域与已核 baseline 指定区域逐像素一致后，原生 move/click/type；`typed.png` 显示 `Safarier test`。08:03:07–08:03:12 一次 Enter 返回 `status=ok`、viewVersion 3；`final.png` 显示 “Form submitted / Received!”；`state.stdout` 返回 submitted-form、loading=false、viewVersion 3。主已核截图、步骤和 state。

`navigation-trace.log` 中提交请求 `89E6EEC0-FE58-4630-82ED-DDE382BC2348` 的 broker admission 为 active=false、awaiting=false、uncertain=false；相应前一请求 ACK received；随后 Manager endpoint、Runner decoded/sink、sender authenticated reply 和 broker exchange 均成功。该轨迹只说明本轮成功路径；此前 003 的 347 ms `INDETERMINATE_RESULT` 未复现，根因仍未确定，不能归因 45 秒或 ACK，也不能称已修复。

08:03:16–08:03:18 `disconnect.stdout` 实际为 `cleaned=true`、`terminatedOwnedRunner=true`；`daemon-stop.stdout` 为 ok，持有的 daemon 退出 0（`daemon-exit.json`），socket 和本轮 artifact 目录不存在（`summary.json`）。这是本轮协议回执，不改变此前 003 的 cleanup false/true 结果。

## 最终只读状态与限制

08:05:34 UTC 同步只读检查：指定 App 唯一 Manager 仍运行（launchDate `1794211325.2066011`），accessory/inactive、无 owned 窗口；未发现该 Runner 或 controller；该 profile 锁 flock held=false，原 artifact 目录及 runtime socket 不存在。Manager 由 noop 后台路径启动，本轮没有可见 Manager 窗口验收，也没有自动打开管理窗口。PID 只用于观察归属，不用于控制路由。

用户反馈美东 03:02:44–03:03:18 当时操作其他应用“未发现干扰”；该反馈仅限用户报告的时段，不推广到其他时段。此后未追加 GUI 或输入，保留当前 Manager。
