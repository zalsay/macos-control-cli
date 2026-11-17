# sfa 与 MCC 执行语义对齐

日期：2026-11-17。主 Agent 对照源码；本轮只修改文档，没有修改执行代码、打包或操作浏览器。

## 基线与结论

MCC：`/Volumes/RC500/dev/chrome-control-cli`，分支 `codex/host-auto-takeover`，HEAD `f5a1cac5c4cd44383499147ee1a98cd44db46e80`。该目录有未提交修改，本记录描述当前工作树，不能当作该提交或已安装版本的验证结果。

sfa：`/Volumes/RC500/dev/safarier`，分支 `mcc-safarier`，包含前几轮未提交修复。完整策略目录见 [拦截策略梳理](2026-11-16-control-interception-audit.md)。

用户要求的对齐目标是：授权后执行命令，回执只描述执行事实，页面效果由 agent 通过 observe 判断。MCC 的普通鼠标和键盘路径符合这种执行与效果分离方式，但 MCC 仍有权限、焦点、几何、暂停、协议和传输检查，不能称为所有层面都没有拦截。

## MCC 实际执行路径

`CLI → execution → daemon → Service → native helper JSONL → ChromeInput.send → CGEvent → sent:true`

- `src/service.rs::input`（约 753 行）把截图像素换算为屏幕坐标，调用 helper；要求 helper 返回 `sent:true`，然后返回执行回执。
- `swift/main.swift`（约 76 行）分发 observe 和输入；`swift/Input.swift::send`（约 392 行）创建并投递鼠标/滚轮/Unicode/键盘事件，末尾返回 `sent:true`。普通输入不读取 DOM、目标 URL 或页面加载结果。
- 控制范围是整个浏览器窗口，含地址栏和标签栏。普通操作没有独立 navigate/back RPC；可用 Cmd+L、输入 URL、Enter 操作地址栏，或操作浏览器工具栏。这是源码能力说明，本轮没有实测导航或后退。
- `src/service.rs::observe`（约 623 行）独立截图/OCR，调用方决定页面是否符合预期。

## 差异与 sfa 调整方向

| 环节 | MCC 普通操作 | sfa 当前 registered 路径 | 对齐方向 |
| --- | --- | --- | --- |
| 浏览器导航 | 不安装网页导航代理，不裁决重定向、history 或页面加载结果 | `OwnedBrowserAutomationPage.attachRegistered` 安装 `BoundFixtureNavigationDelegate`，导航不符合内部关联规则会 cancel/block | 复用浏览器原有正常导航/UI 功能，取消 control 专设的页面行为白名单 |
| 文本输入 | 向目标窗口投递键盘事件，不检查 DOM 输入框类型 | `requireInternalTextEligibility` 检查 activeElement，只接纳部分 textarea/input | 让原生输入接收方处理输入，不由 sfa 判断页面元素是否适合输入 |
| 回执 | 输入事件送出后返回 sent，不确认页面效果 | navigate 已有提交回执，但随后页面事件仍可撤销 Binder，使回执传输失败 | 页面事件与请求回执解绑，已完成的提交事实不能被后续跳转推翻 |
| 截图帧 | 最近 32 帧可复用，无帧时间硬过期；检查连接、保留范围和窗口几何 | 最新帧、版本、短 deadline、generation 等共同限制输入 | 取消页面版本和时间导致的额外执行封锁；坐标转换必须仍有明确坐标系 |
| 会话 | 本地 Service 连接无 sfa 式 90 秒 generation；远程 Host 有另外的生命周期 | 90 秒 generation、idle 清理、命令预算及页面事件关闭相互影响 | 普通页面变化和空闲不应撤销控制；命令 I/O 超时与会话寿命分开处理 |
| 普通操作失败 | 焦点、暂停或几何错误通常保留连接，可继续 observe | 页面/目标策略错误可能一路触发 beginClosing，连带 observe/release 失效 | 操作错误局限于该操作；观察与释放不依赖页面是否符合预期 |
| 释放 | `disconnect` 请求 native cancel，确认 cancelled 后清连接；不检查网页 | 清理与 generation/Binder/导航状态耦合 | 独立停止输入、交还资源，报告实际交还事实 |

主要 sfa 入口：`OwnedBrowserAutomationPage.swift` 的 `attachRegistered`、`checkedObjects`、`checkedOwnedObjects`、`perform`、`beginRegisteredPageNavigation`、`requireInternalTextEligibility` 和 `BoundFixtureNavigationDelegate`；`BrowserSession.beginRegisteredControl`；`BrowserWindowController` 原有 navigation/UI delegate；Manager、Runner 与 Binder 的关闭和回执路径。

对齐的是执行语义，不要求复制 MCC 的前台 CGEvent 后端。sfa 已有正常浏览器功能和原生输入路径，应先沿这些路径收缩策略。当前后台输入还依赖 C/ObjC activity 的条件，必须与 Swift 层一起处理，不能只删上层 guard，留下底层继续拒绝，也不能另叠一套执行框架来掩盖问题。

## 需要准确区分的执行事实

1. Agent 开关授权、参数可解析、目标真实存在、系统权限和实际 IPC/原生调用错误，是执行事实。它们不证明网页操作成功或失败。
2. MCC 仍可能 HELPER_TIMEOUT/EOF/PROTOCOL 并清除连接（`src/service.rs` 约 258 行、`src/native.rs`）。它没有把真实投递未知伪装成 sent，也没有自动重放命令。sfa 同样应报告真实投递状态，不应把所有错误替换成成功。
3. MCC 的 `release_pending` 在取消未确认时只允许 observe/disconnect；这属于 MCC 的具体机制，不意味着用户要求 sfa 原样照搬。
4. MCC 的可选 `click-target` 自行 observe/OCR/JEV 选点，再调用普通 input，返回 `click_sent`、`effectVerified:false`（`src/service.rs` 约 699 行）。这是可选目标选择，不是操作后效果确认。agent 自主选点路径应直接使用坐标操作，执行核心不能强制经过语义裁决。
5. MCC 的 `select-file` 有文件对话框专用确认，不能把普通鼠标/键盘的 sent 契约泛化为每个 MCC 命令都只返回 sent。

## 落实顺序与验收边界

先恢复 registered 浏览器的正常导航、历史和 UI 行为，并解除页面回调对控制通道/回执的撤销；再统一原生输入与会话生命周期，清理 DOM、页面版本、固定寿命和前后台状态带来的额外封锁；最后验证 observe/release 独立可用。整个过程沿既有功能修改，不再针对 Google 或特定跳转增加例外。

后续只对修改范围做定向测试：导航提交后发生重定向、加载错误或文档变化时回执保持提交事实；输入不依赖 DOM 类型；页面变化后仍能 observe/release；真实目标消失和 IPC 断开如实报告且不重放。随后在用户指定的 Test 环境执行既定多步骤浏览，逐步 observe 判断页面效果。

本记录完成了源码语义对齐，尚未完成上述代码改造，也没有宣称此前 Google 多步骤失败已经修复。
