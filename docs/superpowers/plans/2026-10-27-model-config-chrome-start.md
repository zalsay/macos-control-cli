# 通用模型配置与受控 Chrome 启动（已确认）

基线：`codex/jev-click-target`，HEAD `d8165e19dbb4b79fc6332512755040ae8c3f54d4`；保留本会话尚未提交的 Jev 工作和用户 `.env`。实现版本 0.3.0，不提交、不推送、不覆盖现有安装。

## 契约
- `~/.config/mcc/models.toml` 保存 `default_model` 与 `[models.<name>] url/api_key/model`。完整 Decisions 端点，Bearer 认证，不自动转换 chat/completions。每次 CLI 调用读取配置；旧 `.env` 不再隐式使用，`--jev-key` 只覆盖本次 key。
- `mcc --config` / `show <name>` 脱敏查看；`set <name> --url ... --model ... --api-key-stdin`（支持显式 `--api-key`）；`default <name>`。端点改变必须重新显式提供 key。配置命令不启动 daemon。目录/文件 0700/0600，严格 TOML、原子写入、并发写拒绝、错误不包含原始密钥。
- `mcc --config window --max-width 1600` 写 `config.toml` 的 `[chrome.window]`，默认 1600 原始像素，左对齐且占满主显示器可用高度。
- `mcc chrome start [--url ...]` 创建并验证新 Chrome 窗口，AX 设置/回读位置尺寸，然后复用原 connect。已有连接拒绝启动；不复用/移动其他窗口，不设置全屏/置顶/持续回弹。
- Retina 按实际屏幕倍率转换像素/点。截图保持原像素，宽上限1600，高上限8192，JPEG <1MiB，所有旧身份/焦点/暂停/几何门禁不变。Jev 仍只接收 target + id/label，无坐标，返回 ID 后本地查坐标。
- 发送 key 之前验证 daemon 精确版本及动态 Decisions 配置能力；新 URL/model 贯穿 CLI、service、curl、响应模型校验。

## 实施与验收
1. 先补配置与命令解析失败测试；标准 TOML/URL 解析器，不手写解析。覆盖模式、原子更新、脱敏、端点换 key、stdin、无需 daemon、最新配置。
2. 参数化传输和目标请求/模型验证；扩展语义点击测试，确保普通点击链路不变。
3. Swift 独立实现启动/布局及原像素高截图测试；主 agent 集成 Rust 启动和已有 connect，主 agent 执行全部 code review。
4. 完整 Rust（串行，已知既有并行管道清理时序测试偶发不稳定）、native smoke、release build、package/install smoke（临时目录）。
5. 实机用本次私有 runtime 创建新 Chrome 窗口并核对身份、可用桌面 bounds、截图原像素；不发布、不上传、不更换账号，不绕过 USER_PAUSED。只停止本任务 daemon 并核对 running:false。
