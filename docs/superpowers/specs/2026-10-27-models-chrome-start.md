# 已确认设计：通用模型配置、受控新 Chrome 窗口

用户于2026-10-27确认。实现依据与验收步骤见 [执行计划](../plans/2026-10-27-model-config-chrome-start.md)。

- 模型不固定供应商/模型：`models.toml` 命名 profile，每次CLI读取完整 URL、API key、model，经动态 Decisions 版本门禁进入 service/curl/响应校验。仅 Decisions/Bearer 协议，不新增 chat/completions 适配层。
- `--config` 的 set/show/default 命令只读写本地私有配置，密钥推荐stdin且回执脱敏；明确替代旧 `.env` 隐式读取。已有 key 一次性安全迁移，不改源文件。变更URL须重供key。
- 布局存于独立应用 `config.toml`，`chrome start` 创建、验证、布局本次新窗口，再复用 connect。主屏可用区域左/顶对齐、全可用高、默认宽上限1600原像素；不影响其他旧窗口、不后台钉回。
- 按现有取消/暂停状态建立仅限启动布局的许可，不能用于鼠标键盘；不修改原 input 准备、倒计时、焦点、窗口/几何或暂停门禁。无新OCR复核。
- 原像素截图宽<=1600、高<=8192、JPEG<1MiB，禁止缩放。Retina按显示倍率将原像素宽转逻辑点。
- 主agent独立执行code review。构建与任务私有runtime验收不等于安装、提交或发布；不替换现有安装或关闭用户窗口。
