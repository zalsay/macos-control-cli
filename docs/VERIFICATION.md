# 验证记录（2026-10-19）

> 历史背景：本文保留 Copis 上游实现/验证记录，所述 monorepo 路径及 Electron/COS 部署脚本不属于本独立仓库，不是当前构建步骤。当前入口见 [独立仓库 README](../README.md)。

## 自动化验证

| 检查 | 结果 |
| --- | --- |
| `cargo fmt --check` | 通过 |
| `cargo test --locked` | 27 项通过：协议 1、状态行为 10、CLI 进程 5、异常/安全边界 11 |
| `cargo clippy --locked --all-targets -- -D warnings` | 通过 |
| `./build.sh debug` / `./build.sh` | 均通过，最终保留 release 功能包 |
| Swift helper / 纯回归程序双架构 `-O -warnings-as-errors` 编译 | arm64、x86_64 的 macOS 14 target 均通过；仅 ARM 本机运行 |
| `tests/native-smoke.sh` | 144 项无副作用协议检查 + 3 项纯 fake effect + 6 项焦点 + 7 项 toast 布局 BDD 回归通过 |
| 纯 fake effect 回归重复测试 | 30 次 / 90 个场景通过（Swift worker 验证） |
| CLI 忙碌 / 紧急停止回归重复测试 | 修复测试就绪竞争后，连续 30 次通过 |
| 并行全套稳定性复跑 | helper 初始化独立计时后，worker 连续 3 轮、每轮 27 项通过 |
| 归档 SHA256、解压后命令调用、仓库外源码独立 `build.sh debug` 重建 | 通过 |
| 原生只读权限检查与窗口枚举 | 通过；未请求权限，未截图，未激活或输入 |

Rust 回归覆盖帧反复使用、1970 时间戳的帧仍可输入、非最新保留帧可用、几何变化拒绝输入、坐标缩放与负显示器偏移、连接互斥、输出文件不覆盖、helper EOF、写入/响应超时、cancel ACK 后再强杀、满响应队列、后代持有管道、启动竞争、私有 socket、硬链接日志、non-UTF8 路径、敏感 stderr 隔离。

## 审查修复

- 使用独立 reviewer 执行简化和安全审查，修复 helper 生命周期、启动竞争、日志和 socket 边界；环境未提供专用 `@code-simplifier` 工具，未声称调用该工具。
- 独立 Swift 集成审查发现取消 ACK 后仍可能提交后续 AX 抢焦点操作；通过同锁 effect 提交边界和纯 fake 回归修复，独立 reviewer 定向复核通过。
- 最终复跑发现 BUSY 测试提前轮询 status 会先占互斥锁，偶发使 type 按预期收到 BUSY；通过假 helper 输入就绪握手固定测试前提，生产语义未修改。
- 另复现 macOS 并行启动时脚本 helper 停留在 `_dyld_start` 超过原 2s 就绪预算；将测试初始化上限独立为 8s、总 watchdog 12s，ready 后仍保留 3s watchdog、180ms request 超时及执行/清理 <2s 断言。生产超时未修改。
- 保留功能包边界，没有改动 Electron、现有 Copis CLI、根 README/AGENTS 或部署下载链。

## 未验收范围

- v0.1.1 已在用户授权下执行真实键盘导航与焦点回归，详见 [FOCUS-VERIFICATION.md](FOCUS-VERIFICATION.md)。真实鼠标点击、截图内容及 Retina/多屏幕映射尚未验收。
- Intel 为交叉编译验证，没有 Intel 实机运行结果。
- 本地 ad-hoc 签名不等于 Developer ID 公证分发；系统 TCC 权限是否延续取决于安装路径和代码身份。
- `_AXUIElementGetWindow` 非公开系统符号；若未来不可用，工具会拒绝输入，不猜测其他窗口。
- cancel 不能撤回已提交给系统的操作；异常 helper 在 250ms 内未 ACK 时仍会强杀，不能承诺其完成了 held 释放。
- 本地修复在隔离 worktree 开发并整合到 main；尚未推送 GitHub 或发布 COS。

## v0.1.2 原生操作提示

新增原生顶部提示及显式 AppKit 回归；受管 CLI 真实验证只读不提示、恢复前台后显示、连续输入不刷新计时与停止清理。详见 [TOAST-VERIFICATION.md](TOAST-VERIFICATION.md)。实际视觉仍由用户确认。
