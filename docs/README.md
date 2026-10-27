# Documentation / 文档索引

## Current standalone guides / 当前独立使用指南

- [English README](../README.md)
- [中文 README](../README.zh-CN.md)
- [完整使用说明](../USAGE.md)
- [Agent 接入、协议与 Python 调用闭环](AGENT-INTEGRATION.md)
- [执行门禁与暂停/继续](EXECUTION-CONTROL.md)
- [Jev 单次 OCR 语义点击](JEV-CLICK-TARGET.md)：`click-target`、`--jev-key`、云端文字发送、守卫与投递回执。
- [OpenRouter Jev验证与当前边界](JEV-OPENROUTER-VERIFICATION.md)
- [v0.2.5 Jev历史验证快照](JEV-VERIFICATION.md)
- [v0.1.11 OCR 验证记录](OCR-VERIFICATION.md)
- [v0.2.0 通用应用窗口验证](GENERAL-APPS-VERIFICATION.md)
- [v0.2.1 点击前鼠标轨迹](CURSOR-MOTION.md)
- [v0.2.2 Chrome顶部提示条](TOOLBAR-TOAST.md)

Build from the repository root with `bash ./build.sh`; no Copis/Electron/Bun deployment scripts are needed. Version 0.1.11 preserves the original executable name and protocol.

## Historical verification / 历史行为验证

下列记录描述当时的本机测试，不代表所有平台和当前环境均已验收：

- [截图](CAPTURE-VERIFICATION.md)、[坐标](COORDINATE-VERIFICATION.md)、[焦点](FOCUS-VERIFICATION.md)、[指针归属](POINTER-VERIFICATION.md)
- [文件选择](FILE-DIALOG-VERIFICATION.md)
- [控制条](TOAST-VERIFICATION.md)、[倒计时](COUNTDOWN-VERIFICATION.md)、[原像素与控制条](PIXEL-TOAST-VERIFICATION.md)、[原生三联按钮](TRAFFIC-LIGHTS-VERIFICATION.md)

## Upstream integration history / Copis 上游集成背景

以下内容为历史资料，引用的 `apps/electron/`、仓库级 `scripts/`、`deploy.sh` 和 COS 更新系统不在本仓库，不要求独立使用者运行：

- [原始设计](SPEC.md)、[实施计划](PLAN.md)、[早期验证](VERIFICATION.md)
- [组件集成](COMPONENT-INTEGRATION.md)、[组件验证](COMPONENT-VERIFICATION.md)
- [Electron 后端契约](ELECTRON-BACKEND-CONTRACT.md)、[主分支集成](MAIN-INTEGRATION.md)
- [Copis 统一更新与部署](UNIFIED-UPDATES-DEPLOY.md)

- [通用模型配置（URL/key/model）](MODEL-CONFIG.md)
- [Chrome启动与固定布局](CHROME-START.md)

- [v0.3.0模型配置与Chrome启动验证及待授权边界](V030-VERIFICATION.md)

- [v0.3.1显式授权与Chrome实机验收](V031-VERIFICATION.md)
