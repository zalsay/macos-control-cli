# Native application dialogs / 原生应用弹窗（v0.2.3）

## 中文

`desktop-control` 可以把经过原生身份核验的应用弹窗作为**独立窗口**连接，不再只列出绘制层级为 0 的普通窗口。`copis-chrome` 的 Chrome-only 范围不变，不能复用 Chrome 的连接或截图坐标去操作微信授权窗。

### 边界

- 所属进程必须是具有明确 bundle ID 的普通应用；后台、辅助进程不会因本次变更获得控制权限。
- 非零层级必须低于系统菜单层，并通过 AX 原生窗口 ID、PID、角色、子角色与严格几何交叉核验。支持 `AXWindow` 下的 `AXDialog`、`AXSystemDialog`，不凭窗口标题、相似位置或网页内容识别。
- 列出这类弹窗需要已有辅助功能权限；只读枚举不会申请权限或激活应用。普通层级 0 窗口保持原行为。
- 指针动作可以操作不成为 key window 的原生面板，但目标应用仍必须具有前台归属与 `AXFrontmost`，并通过实际指针归属检查。键盘输入仍要求精确的窗口焦点，不能误投到应用主窗口。
- 某些应用未实现 AX 点查询。只有 SLS 实际命中能力可用且明确的 `notImplemented` 才允许使用重新核验的原生弹窗身份作为 AX 证明；前后的两次 WindowServer/SLS 实际命中检查仍必须通过。真实命中其他窗口、权限关闭、查询超时或其他错误不回退。
- 菜单、状态栏、普通浮动面板、未知浮层、任意子窗口和系统权限对话框不因本次更新自动获得支持。弹窗关闭、变更、遮挡或人工接管后停止输入，不自动切换到其他窗口。

### Agent 调用

1. 用户明确授权具体操作，例如本次视频号登录所需的昵称/头像授权。
2. 通过 Chrome 连接点击登录入口。
3. 使用通用入口执行 `windows --app com.tencent.xinWeChat`，重新选择真实出现的微信弹窗；空标题不代表主窗口或无效窗口。
4. 明确结束本任务的 Chrome 输入控制，再连接微信弹窗，避免同时运行两个控制回路。
5. `observe` 获取该弹窗的原像素截图与 OCR，确认平台、授权内容和按钮；不能把任意“允许”当作已获授权。
6. 使用该连接的 `frameId` 与 OCR 原像素坐标执行 `click`。观察弹窗是否关闭，并回到 Chrome 只读确认登录结果；`sent:true` 不等于业务成功。
7. 在 `finally` 中断开并停止**本任务**的 daemon，确认 `running:false`。不要停止其他任务的运行目录。

```bash
# 整个版本目录保留 helper 和 assets，不只复制一个二进制。
DESKTOP_CLI='/绝对路径/copis-chrome-0.2.3-darwin-arm64/desktop-control'
export COPIS_DESKTOP_RUNTIME_DIR="$(mktemp -d /tmp/dialog-control.XXXXXX)"
"$DESKTOP_CLI" windows --app com.tencent.xinWeChat
# 用实际返回的 windowId / connectionId / frameId 调用 connect → observe → click。
# 受宿主环境管理的进程如果不能通过 daemon start 常驻，用受控后台任务运行 daemon run；不要反复重建连接掩盖退出。
```

输入被暂停时检查 `error.reason`：`code:FOCUS_LOST, reason:USER_PAUSED` 表示暂停门禁，不足以证明 macOS 的窗口焦点真的发生了变化。停止输入，等待用户通过控制条继续，不新建 runtime 绕过暂停。

### 回归测试

```bash
# 无桌面输入的角色、层级、身份、错误分类回归也纳入 native-smoke.sh。
bash tests/native-smoke.sh /绝对路径/copis-chrome-helper

# 显式桌面测试：创建并只操作本次隔离 AppKit 应用，不访问微信或 Chrome。
# 会占用鼠标；测试期间不要切换应用或移动鼠标。
bash tests/native-dialog-smoke.sh /绝对路径/desktop-control
```

隔离测试检查层级 23 的非激活弹窗枚举、连接、原像素截图/OCR与实际按钮点击，并拒绝菜单/状态层、键盘错投、覆盖窗口穿透和关闭后的旧坐标操作。测试不能代替用户对控制条视觉效果的实际窗口确认，也不代表所有应用原生面板都已验证。

### 本次验证（2026-10-23）

92 项 Rust 测试、153 项无副作用原生 JSONL 检查及新增原生窗口/指针错误分类 BDD 通过。隔离原生弹窗真实点击和安全负例通过；一次临时测试应用激活失败后，单独复跑通过，未为此放宽守卫。控制条对象回归通过，不代替用户视觉验收。

真实微信的原生角色已读到 `AXWindow / AXSystemDialog`、层级 23。完整登录测试中一次因 `USER_PAUSED` 停止；最后一轮发现活动页已切到其他平台后，在输入前停止。未点击真实微信“允许”，不声明微信端到端登录已验证通过。

## English

Version 0.2.3 lets `desktop-control` connect to verified native application dialogs as **separate windows**, including eligible non-zero window levels. The Chrome-only entry point remains unchanged. Never reuse a Chrome connection, frame or coordinates for a WeChat authorization dialog.

A non-zero-level window must belong to a regular application, remain below the system menu level, and have matching native AX/CG window identity, PID, role, subrole and exact bounds. Only native `AXWindow` dialogs/panels with `AXDialog` or `AXSystemDialog` subroles qualify. Enumeration requires existing Accessibility permission without requesting permission or activating an app. Level-zero windows retain their existing behavior.

Pointer operations can address a non-key native panel while retaining exact application-foreground ownership, `AXFrontmost`, geometry and actual input-target checks. Keyboard operations still require exact key-window focus. Only an explicitly unimplemented AX hit-test with available WindowServer/SLS hit-testing may use freshly verified native-dialog identity instead; both surrounding WindowServer/SLS hit-tests remain mandatory. Permission errors, timeouts and a successful hit on another window never fall back.

List windows with `desktop-control windows --app com.tencent.xinWeChat`, select the actual dialog, connect and observe it, verify the requested authorization and the caller's explicit user approval, then click using its own frame and original-pixel OCR coordinates. An empty title is possible. Ending the Chrome input loop before controlling WeChat avoids competing controllers. Observe dialog closure and the resulting browser state separately: input delivery is not business success.

Menus, status windows, ordinary floating panels, unknown overlays, arbitrary child windows and system permission dialogs are not automatically supported. A closed/replaced dialog, obstruction or user takeover stops input instead of redirecting it. `FOCUS_LOST` with `reason:USER_PAUSED` is the compatibility representation of the pause gate, not proof of an OS focus transition. Wait for the user to resume; never restart a runtime to bypass a pause.

The explicit `tests/native-dialog-smoke.sh` fixture exercises real native input only in its private AppKit application, including non-key panels, OCR/button delivery and negative keyboard, obstruction and closed-window cases. Always disconnect, stop only the task-owned daemon, and verify `running:false` in cleanup. Automated functional checks do not replace user-window visual acceptance.

Validation on 2026-10-23: 92 Rust tests, 153 side-effect-free native JSONL checks, native-dialog identity/hit-test BDD, control-bar object checks and the isolated real-input fixture passed. One temporary fixture activation failed before an isolated rerun passed; guards were not weakened. The WeChat end-to-end flow remains unverified: one attempt stopped on `USER_PAUSED`, and the final attempt stopped before input because the active Chrome tab was no longer the target platform. No real WeChat Allow button was clicked.
