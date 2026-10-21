# 独立 Chrome 桌面 CLI 实现计划

> 历史背景：本文保留 Copis 上游实现/验证记录，所述 monorepo 路径及 Electron/COS 部署脚本不属于本独立仓库，不是当前构建步骤。当前入口见 [独立仓库 README](../README.md)。

> **For agentic workers:** 使用 subagent-driven-development 与 test-driven-development 按任务执行；每步先验证失败，再实现并回归。

**Goal:** 交付不依赖 Electron 的 Rust + Swift Chrome 桌面自动化功能包。
**Architecture:** Rust CLI 通过私有 Unix socket 调用单实例 daemon；daemon 通过 JSONL 管道调用 Swift helper。连接和帧状态由 daemon 持有，原生截图与输入只在 Swift 层实现。
**Tech Stack:** Rust 2021（标准库 + serde/serde_json）、Swift / AppKit / ScreenCaptureKit / CoreGraphics，macOS 14+。
**Spec:** 同目录 SPEC.md。

## Global Constraints

- 只修改本功能包；不修改根 README/AGENTS 与现有 Electron 调用链。
- 中文注释与日志；stdout 为 JSON，无图片 base64 或用户输入原文。
- 系统授权不重复自建；连接跨命令保留；帧可复用、无 30 秒硬过期。
- 不自动执行真实浏览器输入，不将 Electron UI 截图当作用户验收。

## Task 1：Rust 状态与命令契约（主 Agent）

**Files:** src/protocol.rs、src/args.rs、src/service.rs、tests/behavior.rs。
**Interfaces:** Native::request(Value) -> Result<Value>；Service::execute(Value) -> Result<Value>。
- [x] 写 BDD 测试并确认 RED：帧复用、旧帧、几何变化、输入白名单、单连接互斥。
- [x] 实现最小服务与参数解析并确认 GREEN。

## Task 2：Swift 原生 helper（并行 worker）

**Files:** swift/*.swift、tests/native-smoke.sh。
**Interfaces:** 请求 {id,action,...}，响应 {id,ok,data?,error:{code,message}?}，单行 JSON；cancel 可打断 actionQueue。
- [x] 先写无需权限的协议与参数测试并确认 RED。
- [x] 实现权限、窗口、截图、输入、取消；swiftc 编译并通过原生 smoke。

## Task 3：进程边界与打包（主 Agent）

**Files:** src/native.rs、src/runtime.rs、src/daemon.rs、src/main.rs、tests/cli.rs、build.sh、USAGE.md。
- [x] 写独立进程 BDD 测试并确认 RED。
- [x] 实现私有 socket、锁、原生 helper 超时/EOF、daemon 生命周期、截图输出文件保护。
- [x] 独立构建两个二进制与功能包归档，运行真实只读权限/窗口枚举 smoke。

## Task 4：审查与交付

- [x] code-simplifier 审查组件职责、重复与不必要抽象，修复有证据的问题。
- [x] cargo fmt --check、cargo test、cargo clippy --all-targets -- -D warnings、build.sh、原生 smoke。
- [x] 检查 git diff，只包含独立目录；说明尚需用户确认的系统授权/真实 Chrome 操作。

## 完成说明

独立审查发现的取消抢焦点 P2 已修复并通过定向复核；Rust 异常与安全回归已通过。详见 VERIFICATION.md。专用 @code-simplifier 不在本环境工具集中，已采用独立 reviewer 的简化审查替代，未声称调用该工具。归档解压后的独立源码可在仓库外通过 build.sh debug 完整重建。变更保留在 worktree，未提交或推送。
