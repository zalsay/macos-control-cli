# 0.3.6 Host 自动软暂停接管（开发候选）

基线 main/tag 0.3.5.1：`a37c3650c77d0f3f3bca1b8067a5cd028e863214`。用户确认的边界及实现任务见 [spec](superpowers/specs/2026-10-28-host-auto-takeover.md) / [plan](superpowers/plans/2026-10-28-host-auto-takeover.md)。候选构建不是安装、推送、发布或远端部署。

## 原链路上的实现

- Host 仍经已绑定 owner/PID 的 daemon 预留和原 Service/Native 输入链；仅同 owner 的新序号、新输入意图，原连接和有效帧可触发软恢复。没有新增执行器、OCR 复核、公开 resume 指令或客户端绕过字段。
- Native 区分鼠标活动、焦点软暂停与明确人工停止、传输硬暂停。明确停止在已有软暂停上升级且不会被软事件降级。
- 恢复通过原 transport 通道，以同 lease、精确旧 epoch 做原子检查；推进一代 epoch，先进入 awaitingCountdown。原目标/焦点/几何/权限门禁和控制条展示之后才开始三秒倒计时。旧请求/permit 不可恢复。
- ACK/能力/状态不确定、owner 失效、错误连接或帧、非输入请求、旧序号和恢复锁都不允许自动恢复。观察/status 不接管。硬暂停继续原明确确认或 Host 本地恢复流程。
- Host/client 的固定错误提示说明软/硬区别，但保留原 FOCUS_LOST + USER_PAUSED 兼容字段与诊断脱敏。本机非 Host 错误文案与手动继续行为不变。

## 验证分层

- Native fake-clock/严格解码、原完整 BDD 和无副作用 JSONL；不投递真实系统输入，不请求系统授权。
- Rust daemon/service 新请求、同 lease/epoch、安全边界及真实 loopback WSS Host/client 进程测试。WSS 测试的 Native 为测试替身，不能冒充真实桌面验收。
- 候选包构建、签名、源码/文档链接一致性，以及临时 HOME/prefix 中的安装/升级/回滚和真实 helper 默认发现。
- 精确计数和 RED/GREEN/全量命令回执保存于本地 ignored `target/host-auto-takeover/`，不包含到 Git/分发包。

原生实现可由 Terra worker 编写；所有 code review 与最终合并判断仅由主 agent 执行。当前未据此更新真实安装、远端服务、Git main 或历史 tags；真实远端 Chrome 的无人值守接管仍须在完整同版本升级后单独验收。

## 测试夹具启动预算

全量中出现的 fake-helper 首次只读握手三秒超时发生在用例控制断言之前。增加可确定复现的 3.2 秒冷启动回归后，仅测试 Fixture 在启动就绪阶段使用十秒预算，并在首次只读 permissions 确认后立即还原原三秒请求预算；只发送一次就绪请求，不重试 Claim 或输入。setter 仅在 cfg(test) 存在，生产 helper/传输侧带超时不变。此项提高夹具冷启动容忍度，不宣称修复了操作系统调度延迟本身。

## 本轮回执

- Rust 1.89 串行全量：340 passed、0 failed、1 ignored（原付费模型测试）；fmt/Clippy/diff 检查通过。
- 完整 Native BDD 与 186 项无副作用 JSONL 通过，包含软恢复、手动/传输升级、旧 permit、溢出和严格解码。
- 新软暂停/明确停止用例在真实 loopback WSS Host/client 进程中通过；完整 release 进程组 18/18。该组仍使用 fake Native，不代表真实鼠标键盘已验收。
- 临时 HOME/prefix 安装、旧归档迁移、回滚及默认 helper 发现通过。双语 README、Agent/Jev 指南和帮助文本同步，最终归档重新构建校验。
