# v0.1.5 原生文件选择修复（2026-10-20）

## 问题与证据

网页上传按钮打开的“打开”文件选择框在本机是 Chrome 附属的 AppKit `AXSheet`，标识为 `open-panel`。进入“前往文件夹”后，焦点变成 `GoToWindow` sheet。它们通过已授权主窗口的 `AXChildren` 关联；`AXSheets` 在本机返回空值。文件选择框中部分远程控件的窗口 ID 为 0，不能按普通网页窗口的几何或坐标规则控制。

原通用输入要求焦点窗口 ID 与授权网页主窗口完全一致，因此原生面板出现后会主动拒绝输入。`Cmd+Shift+G` 也不在普通网页快捷键白名单中。该错误不能据此解释为系统丢弃所有合成事件：隔离 Chrome 测试已验证快捷键可打开 GoTo sheet，AX 可以写入路径并按下原生“打开”按钮。

真实集成还复现了后台 Chrome modal 的 `AXWindows` 查询返回 `-25204`（cannotComplete），以及激活后几何检查失败。文件选择不依赖截图坐标，v0.1.5 在验证原 Chrome PID/窗口仍存在后激活应用，并有界重读精确 AX 窗口；选择过程依靠窗口身份和原生 sheet 归属校验，不复用网页截图几何。单次动作固定首次精确验证的 AX 主窗引用，避免 modal 切换时反复枚举 `AXWindows`；预期切换期间只读等待 AX 焦点与子树同时稳定后才继续输入。

## 实现边界

- 新增 `select-file --connection <id> --path <absolute-file>` 和 Agent 工具 `ChromeDesktopSelectFile({controlId, path})`。
- 复用当前控制连接；不需要 `frameId` 或第二次授权。通用网页输入、截图和指针校验规则不变。
- Rust 与 Swift 均校验文件路径及普通文件可读性，支持中文、空格和指向普通文件的符号链接。错误消息和运行日志不回显路径或文件内容。
- 只从授权主窗口的原生 sheet 子节点定位唯一 `open-panel`，跟踪同一 panel ID，以及原窗口或面板下的 `GoToWindow`。其他 Chrome 窗口、Finder、Save 面板、网页 AX 子树或未知结构不能通过该能力被控制。
- 快捷键及每个 AX 副作用均遵循取消代次。`Cmd+Shift+G` 只在该专用流程中发送，不扩大通用按键白名单；回车前确认仍是同一个 GoTo 路径输入框及预期路径，避免发送到网页。
- 路径写入同时设置字段的 `AXFocused` 和应用 `AXFocusedUIElement`，再确认；只有 GoTo 已关闭、原 Open 面板按钮可用时才提交选择。
- 总等待上限 12 秒；只有原生“打开”动作提交后且原面板消失才返回 `selected: true, dialogClosed: true`。该结果不代表网页上传或业务发布成功，Agent 必须再观察页面。
- 具体错误使用 `FILE_DIALOG_NOT_FOUND`、`FILE_DIALOG_UNSUPPORTED`、`FILE_DIALOG_UNVERIFIED`、`FILE_DIALOG_TIMEOUT`、`FILE_NOT_READABLE`、`FILE_SELECTION_FAILED`，Electron 映射为对应的 `CHROME_` 错误。可恢复错误保留连接。

## BDD 回归

```text
Given 原授权窗口已打开原生文件选择框
When 选择可读的本地普通文件
Then 不需要网页 frameId 或重复授权
And GoTo 路径确认完成，Open sheet 关闭
And 网页收到预期文件名，原连接仍有效

Given 焦点属于其他窗口/进程、Save 面板或未知 sheet
When 尝试选择文件
Then 不向其发送路径、回车或点击

Given 错误连接、不可读文件或尚未打开选择框
When 调用 select-file
Then 返回具体错误且不会吊销原有效连接

Given 输入已取消
When 旧动作尝试后续 AX 操作或快捷键
Then 取消代次检查阻止后续副作用
```

无桌面副作用回归：

```bash
cargo test --locked
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
bash tests/native-smoke.sh
```

显式真实回归：

```bash
./build.sh
bash tests/file-dialog-smoke.sh "$(pwd)/dist/copis-chrome-0.1.5-darwin-arm64/copis-chrome"
```

真实回归自行创建独立 Chrome profile、仅绑定 loopback 的 HTML 页和生成的 `.txt`。测试页的 `change` 事件只更新标题，POST 被拒绝、CSP 禁止连接与表单提交；AX 检查最终标题和 sheet 关闭情况，不查看或分析截图。测试结束只关闭本测试拥有的 Chrome 进程及私有 CLI runtime，不向用户已有窗口发送点击或输入，不停止其他 Agent 连接。独立冷 Helper 场景会暂时恢复测试前的应用焦点，明确断言 Chrome 在后台；测试结束恢复原前台应用。

## 验证结果与部署

Rust 全套 39 项、格式与 Clippy 检查通过；原生 153 项 JSONL smoke，以及焦点、几何、取消、提示、采集、指针和新增文件对话框 BDD 通过。文件选择等待期间发生取消/超时的回归先 RED（查询返回 ready 后误判成功），修复为查询前后校验后转绿。完整正式 CLI 在普通场景与明确后台/冷 Helper 场景连续两轮通过，均使用中文空格路径并在网页核对预期文件名，无实际上传。相关 15 个 Bun 测试文件共 282 项通过（接入/权限/帧复用/暂停恢复、部署版本锁及 Worker 构建 smoke）；全仓 typecheck、Electron 主进程和组合 CLI/Pi Worker 构建通过。构建 smoke 已加入第八个 `ChromeDesktopSelectFile`，真实编译产物的模型请求验证了工具注册；缺少该工具的产物回归先 RED 后 GREEN。原生与 TS 独立只读复核及等价代码简化检查均通过，无剩余 P1/P2。本机提供 darwin-arm64 产物；Intel 构建与 TCC 分发身份仍需在对应环境验证。

组件更新只影响新连接；已有连接继续使用旧组件。独立 CLI 可直接使用 v0.1.5。内置 Agent 的新增工具定义在主程序/Worker 中，因此需要重启包含本次改动的开发环境，或构建并安装对应应用版本。Electron 实际界面交互由用户确认，自动化验证不代替用户验收。未发布 GitHub、COS 或线上 manifest。
