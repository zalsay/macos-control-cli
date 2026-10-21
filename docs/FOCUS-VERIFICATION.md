# v0.1.1 焦点校验修复与实测（2026-10-19）

## 症状与定位

真实 CLI 在 connect、observe 成功后，第一个 `press Cmd+T` 返回 `FOCUS_UNVERIFIED`。屏幕录制、辅助功能权限均为 true；NSWorkspace 前台 PID 和 Chrome 应用的 AXFocusedWindow 均与选定窗口一致。

临时只读诊断确认：system-wide 的 AXFocusedApplication 在主线程、后台线程均返回 `kAXErrorNoValue`（-25212），虽然 out 参数非 nil；AXFocusedUIElement 同样返回 noValue。错误响应中的 out 值没有被采信。Chrome 的应用级 AXFrontmost 查询成功，且能正确区分 Chrome 与其他应用的前台状态。

v0.1.1 改为联合验证 NSWorkspace 前台 PID、Chrome AXFocusedWindow 精确窗口 ID、严格成功且为 CFBoolean true 的 AXFrontmost、AX/CG 精确几何；几何查询前后各核对一次前台 PID、AXFrontmost 与精确焦点窗口；鼠标输入的最后一次焦点检查位于遮挡/几何查询之后。任一身份、几何、状态检查失败仍拒绝输入。激活超时保留最后一次具体拒绝原因。取消提交锁、事件 generation、读取不切前台、帧可重复使用与无时间硬过期的行为保持原契约。

## RED / GREEN 与边界验证

新增显式运行的 `tests/focus-smoke.sh <Chrome窗口ID> <其他应用PID>`，只切换指定应用焦点，不截图、不创建或发送键盘鼠标事件；不会随默认协议 smoke 自动运行。

- 修改生产代码前运行，稳定复现 `FOCUS_UNVERIFIED`，退出码 1。
- 修改后真实 ARM macOS 回归通过：激活精确目标窗口成功、拒绝同一 Chrome 的另一窗口、拒绝帧几何不一致、切到指定其他应用后拒绝已失焦 Chrome。
- 独立复审发现并修复检查中途切换到同一 Chrome 另一窗口的竞态；6 项纯 fake 焦点 BDD 先 RED 后 GREEN，覆盖尾部换窗、跨应用、读数无值、几何失败与稳定焦点。
- 原生协议 smoke：144 项无副作用 JSONL 校验、3 项 fake cancellation 与上述 6 项焦点回归通过。
- Rust：27 项测试、fmt、严格 Clippy 通过。
- Electron 组件客户端、Chrome 模块安装/更新测试通过；组件版本锁、归档准备、manifest 与 deploy 参数回归通过。
- Cargo.toml、Cargo.lock 与功能模块版本锁同步为 0.1.1；真实 release 双二进制归档通过发布准备器校验。

## 受管组件与真实导航

通过现有 functional-module manager 校验本地产物 SHA256、解包、激活到 `~/.copis/modules/`。受管解析器确认组件版本为 0.1.1；没有请求额外系统授权，没有发布到 COS。

使用该受管 CLI 和私有临时 runtime，连接指定的 Chrome 窗口，取得一帧后依次执行：

1. `press Cmd+T`：`sent: true`。
2. `press Cmd+L`：`sent: true`；通过 AX 地址栏确认新标签页尚未出现目标 URL。
3. `type https://creator.xiaohongshu.com/`：`sent: true`。
4. `press Enter`：`sent: true`。
5. 等待加载后，窗口标题为“小红书创作服务平台”，AX 地址栏为 `creator.xiaohongshu.com/new/home`。

这些结果结合新标签页导航前后的地址栏变化，验证了本次 CLI 导航成功，而非把原先已存在的网页标题当作成功证据。原生 observe 按输入契约执行，没有查看或分析截图内容。测试 daemon、连接和临时截图目录随后清理，浏览器中的新标签页保留供用户使用。

此次验证涵盖真实键盘导航；未执行鼠标点击、多屏幕/Retina 实机输入、登录或发布内容。Electron 窗口中的预览、组件卡片和 UI 交互仍由用户实际确认；本次不以截图代替 UI 验收。
