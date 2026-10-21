# v0.1.3 Observe 超时排查与修复（2026-10-20）

## 已确认的故障

用户的 ChromeDesktopStart 成功，但 ChromeDesktopObserve 在约 6.1 秒后返回 `CHROME_ACTION_UNCERTAIN`，随后控制暂停。最近会话的两次失败均发生在观察阶段，没有投递点击或键盘输入。

在本机正式安装的 v0.1.2 CLI 中，用私有 runtime 重现同样行为：permissions 显示屏幕录制和辅助功能均 true，windows/connect 正常，observe 返回原生 `CAPTURE_TIMEOUT`。直接调用原 Helper 也能重现，因此不是模型识图、工具参数或 Electron 到 CLI 的调用超时。

系统采样和统一日志显示：SCShareableContent 窗口枚举成功，随后 SCScreenshotManager/ReplayKit 的 XPC 连接反复中断，出现 `NSCocoaErrorDomain 4097`，直到本地 6 秒等待上限触发。原文件签名校验通过；同一二进制的字节副本在临时位置、同长度路径和用户配置目录的新位置均能正常抓图。`/usr/sbin/screencapture` 指定同一窗口也成功。现有证据只确认系统截图链路与原安装文件身份/位置有关，尚未确认更深层的系统缓存或签名归属机制；没有将其归因于用户未授权，也没有声称修复了 macOS 内部问题。

另一个已确认的问题是错误信息丢失：Electron 将多种原生错误统一显示为“Chrome 组件无法完成操作”，隐藏了 Observe 的截图服务超时原因。

## 修复范围

- 新增独立 `CaptureFallback.swift`，仅在截图后端失败或超时时进行只读回退；权限、窗口身份、几何或取消失败不触发回退。
- 系统回退固定执行 `/usr/sbin/screencapture -x -o -a -l <精确窗口ID> -t png <私有路径>`，不调用 shell、不截整屏、不启动交互选择、不写剪贴板、不激活 Chrome。
- 使用 0700 临时目录，采集前后验证目标窗口归属和几何；图像两轴必须与窗口使用相同缩放比例，不允许把裁切内容拉伸成目标区域。最长边不超过 1600，继续使用原来的 JPEG 小于 1 MiB 与 O_EXCL 最终写入约束。
- 子进程有 6 秒上限；启动受 cancellation generation 保护，取消或超时后终止并回收采集进程、清理临时文件；运行期间的进程与私有目录通过同锁 lease 登记，取消 ACK 必须在清理之后。不会重试或重放任何输入动作。
- 回退成功后同一 Helper 继续使用该后端，避免每次 Observe 再等待故障服务；新 Helper 会重新尝试 ScreenCaptureKit。
- 分别标识窗口枚举和抓图阶段超时；CLI 的 Observe 可选返回 `captureBackend`，只允许 `screen-capture-kit` / `screencapture`。
- Electron 对已知错误输出“动作 + 白名单原生错误码 + 固定中文原因”，不透传原生 message、stderr、argv 或连接凭据。
- Cargo、版本锁与发布准备入口同步为独立组件 v0.1.3，协议主版本仍为 1。应用与独立 CLI 的连接、帧复用、输入安全约束未更改。

## 验证证据

1. 错误消息回归先 RED：CAPTURE_TIMEOUT 被替换为泛化提示；修复后 6 个已知故障码均带动作与固定原因，且不泄露测试原文。
2. 新增默认无桌面访问 BDD：成功不重复采集、主后端错误回退、取消/权限/窗口/几何失败直接关闭、成功回退后的后端复用、Retina 缩放、异常图像、截图子进程超时终止与取消后不启动。独立复审发现并修复运行中取消 ACK 过早的竞态；新增 fake 子进程与私有图片测试，先 RED（ACK 早于子进程退出），修复后 GREEN（ACK 后进程已退出且图片目录已清理）。
3. 显式 `tests/capture-background-smoke.sh <窗口ID>` 使用生产回退代码，以模拟主后端超时触发真实单窗口截图，连续两次成功，前台 PID 保持不变。只验证尺寸和进程状态，没有查看或分析图像内容。
4. 通过现有 functional-module manager 安装本机 v0.1.3；受管 CLI permissions/windows/connect/observe 成功，实际 Observe 约 0.3 秒，返回 1212 × 1310 图像。
5. 通过真实 ChromeDesktopComponentClient 完成检查、列窗、连接、原生观察与 JPEG 读取，componentVersion=0.1.3，图片元数据有效，测试 runtime 已停止并清理。
6. Rust 28 项、组件客户端 88 项、服务/焦点 17 项、Chrome 安装更新 35 项、版本锁/发布准备 28 项均通过；fmt、严格 Clippy、工作区 typecheck 和 Electron build:main 通过。默认 native-smoke 保留 144 项协议、3 项取消、6 项焦点、7 项 toast 布局，并加入上述截图回退回归。

上述均为只读验证；没有点击网页按钮、输入文字、导航、修改系统权限或停止其他调用方的 runtime。根 README/AGENTS 未修改。此次没有用截图替代 Electron UI 验收，实际应用中的重新接管与观察结果仍由用户确认。

## 生效与未覆盖范围

本机 active 指针更新为 v0.1.3；正在使用旧版本的连接不会被替换。先停止该会话原有的 Chrome 控制，再重新开始，后续连接将使用新版组件；不需要重授已有效的系统权限。

截图回退在组件内，兼容现有协议 1 的已安装应用；更具体的错误文案位于 Electron 主进程，需要使用包含该源码变更的应用构建才能显示。没有原地修改已签名的 Copis.app，也没有自动重启用户正在运行的应用。

Intel 为交叉编译目标，不代表 Intel 实机验收；真实多屏、最小化/隐藏窗口和锁屏情况不扩大原有支持范围。若系统极端卡住而无法完成清理，不会返回成功取消 ACK，仍由 Rust 原有 250ms 超时终止 Helper；不承诺系统不可终止或外部强杀下的完整清理。v0.1.3 尚未发布 COS，其他机器不会仅通过远端 manifest 自动取得本机产物。
