# 主分支集成交付（2026-10-19）

> 历史背景：本文保留 Copis 上游实现/验证记录，所述 monorepo 路径及 Electron/COS 部署脚本不属于本独立仓库，不是当前构建步骤。当前入口见 [独立仓库 README](../README.md)。

## 原有工具实际调用 CLI

保留已有七个模型工具名和会话鉴权，不新增第二套并行工具：

```text
Pi ChromeDesktopStart / Observe / Click / Scroll / Type / Press / Stop
  → POST /api/internal/agent/chrome-desktop-tool（会话 capability 校验）
  → ChromeDesktopService（授权窗口、互斥、回执与帧复用）
  → ChromeDesktopComponentClient（固定受管组件版本）
  → copis-chrome CLI（Rust 后台进程）
  → copis-chrome-helper（Swift 窗口、截图、鼠标键盘）
```

旧 Electron Swift helper、旧 helper client 和 renderer 图片回传 IPC 已移除，不通过旧实现回退。Electron 视频流只负责可选预览，预览不可用不会阻塞原生观察和输入。

## 合并前验证

- 全仓 `bun run test`：460个测试文件全部通过，每个文件独立Bun进程。
- `bun run typecheck`：全部工作区通过。
- 独立包 `cargo test --locked`：27项通过；Rust格式检查和严格Clippy通过。
- 端到端隔离验证：原有七个工具通过真实 `ChromeDesktopComponentClient` 执行实际Rust CLI；仅将原生桌面边界替换为本机假helper，四个输入动作均实际经过CLI，同一帧多次使用成功，停止后后台进程清理。不操作真实Chrome、不触发系统授权。

## 本地集成边界

合并目标为本地main，不包含GitHub推送或COS发布。主工作区原有四个聊天室未提交文件与本次改动没有重叠；合并前记录其内容摘要与工作区/索引补丁，合并后验证原样保留。不修改根README或AGENTS（需用户允许）。

组件统一管理入口为设置的“关于/更新 → 本地能力”，发布入口为 `deploy.sh --chrome-cli`。真实Electron视觉/交互与Chrome输入仍由用户在实际应用窗口确认。

## 合并后验证修正

主工作区保留了历史Electron安装包，默认测试发现曾误扫 `apps/electron/out/` 内的测试副本，因包内没有源码相对路径而失败。发现规则已仅排除依赖、dist与该打包输出目录，源码和第三方源码测试继续执行，并补充11项目录边界回归。

跨版本连接用例会串行启动多条真实CLI，冷启动期间曾超过Bun默认5秒。仅该用例的整个场景预算改为15秒，不改变任何生产命令超时、取消和回执断言；组件客户端82项回归通过。业务代码与主工作区原有聊天室修改均未因该验证修正而改动。
