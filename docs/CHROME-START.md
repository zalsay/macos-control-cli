# Chrome 启动与固定布局（v0.3.0）

```sh
mcc --config window --max-width 1600
mcc chrome start --url https://creator.xiaohongshu.com/
# 返回原connect合同：connectionId、window、connected，以及created/layout
mcc observe --connection <connectionId>
mcc disconnect --connection <connectionId>
mcc daemon stop
mcc daemon status
```

仅新建本次受控的 Google Chrome 窗口，不枚举后随意挑一个旧窗改大小。默认页面为空白；`--url` 只接受无用户凭据的绝对 HTTP(S) URL。启动前要求屏幕录制和辅助功能权限，可能还需要用户在系统中允许 Automation / Apple Events。已有控制连接时返回 `CONNECTION_BUSY`，不会替换连接、移动原窗或借此绕过暂停。

### macOS自动化权限

在屏幕录制/辅助功能之外，Apple Events 还要求**当前宿主 → Google Chrome**的自动化授权。从v0.3.1起统一接入现有授权入口，不再只检查而缺少申请路径：

```sh
mcc permissions            # 三项只读查询，不主动弹窗
mcc permissions --request  # 显式申请三项权限，Apple Events askUserIfNeeded=true
```

返回新增 `chromeAutomation` 对象：`target:"com.google.Chrome"`、`requested`、`granted`、`status`、`osStatus`。`requested:true` 只表示使用显式申请路径，不代表系统一定再次弹窗，更不代表已经允许；以 `granted` 和 OS状态为准。已经授权时不会强制重置或制造弹窗。状态包括granted、requires_consent、denied、target_not_running、unverified；Chrome未运行时报告target_not_running，请先手动打开Chrome后再申请，不由权限命令自动打开网站或创建窗口。

普通Chrome启动仍做不弹窗检查，权限缺失立即返回 `AUTOMATION_PERMISSION_REQUIRED`，不代点“允许”。显式申请在原生串行工作队列而非AppKit主线程执行；由本人在系统提示中决定。若此前已拒绝，应本人在“系统设置 → 隐私与安全性 → 自动化”中允许实际宿主（例如Codex/ChatGPT、Terminal）控制Chrome，不重置TCC或更换宿主绕过拒绝。旧daemon/helper必须升级本任务实例，不能把缺少新字段的旧回执当成已申请。

冷启动时Chrome尚未运行，系统可能在正常应用启动后请求Apple Events授权；OS仍会执行授权检查。启动所有阶段共用38秒预算；超时不重放动作，可能已创建的新窗不会被自动关闭。尚未获授权前不能宣称实机布局通过。

应用设置单独保存在 `~/.config/mcc/config.toml`（与模型配置相同的目录覆盖/权限策略）：

```toml
[chrome.window]
position = "left"
height = "available"
max_width_px = 1600
```

- 使用主显示器当前 `NSScreen.visibleFrame` 可用区域，左/顶对齐，高度占满，不占用菜单栏和 Dock；不是全屏 Space，也不是置顶。
- 宽度默认取配置最大宽度与可用屏幕宽度的较小者，单位是**原始像素**。例如2x Retina的1600px相当于800逻辑点。支持400–1600配置值；Chrome实际最小尺寸如无法满足该值，会明确失败，不暗中放宽上限。
- 新窗按 CGWindowID/PID/bundle ID 与AX窗口对应，设置并回读尺寸/位置，再经原有 connect 二次核对身份，返回连接凭据。失败不重试点击、不关闭用户窗口。
- 只在启动时应用布局，不后台持续钉回；用户后续移动/缩放仍触发原几何或暂停门禁，不在 observe/click 中偷偷重排。
- 截图保留原始像素，不缩放。宽上限1600px、高上限8192px、JPEG小于1MiB；任一超限返回 `IMAGE_TOO_LARGE`。高度边界放宽是为了全高Retina窗口，不改变同帧OCR/坐标转换或文件预算。

不要对登录是否完成作推断：启动与布局只证明窗口就绪；`sent:true` 只证明事件投递。QR登录仍需要本人扫码和观察业务后置状态。任务结束只清理自己持有的连接/runtime，保留浏览器登录状态。
