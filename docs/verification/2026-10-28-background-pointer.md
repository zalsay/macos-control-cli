# 后台原生悬停与按住状态修复验证

- 日期：2026-10-28T14:54:07.419431+08:00
- 分支：`mcc-safarier`；基线：`2f32d21248deaffd8c8c1152a39912aa46350c7e`。
- 平台：macOS 26.6.2 / arm64；WebKit `21624.5.1.11.3`；Swift 6.3.3。
- 结论：本次范围内修复已通过重复验证；不是完整产品、任意网页或跨版本验收。

## 实现与安全边界

1. 悬停：WebKit 对 inactive 页面且无按键的移动只做滚动条命中。通过本进程的页面活动上下文解决，不调用真实窗口激活；窗口查询仅对已核验 WebKit image 的调用点提供逻辑结果，AppKit/应用本身始终走原查询。
2. 按住状态：使用主线程 TLS 逻辑按钮状态；原生事件发送期间为 down/drag=1、up=0；查询 IMP 在正常返回、异常、嵌套后恢复。静态 C IMP 不会在并发读者还在执行时被释放。
3. 时序：使用原生 pending-mouse completion，不把固定等待当作动作完成；避免多次纯移动合并后阻塞后续点击。输入文字前先等待指针动作与只读状态回执。
4. 后台光标保护：本 Runner 内的 NSCursor 设置/隐藏写入被抑制；主线程且真实 App 为前台时透传原函数。该保护有意常驻至 Runner 退出，以覆盖迟到的按键回执；不是临时查询，不能宣称结束连接时撤销了所有方法替换。其它进程不受影响。
5. 不使用全局 CGEvent 投递、鼠标移动/键盘兜底、AppleScript System Events、DOM click/dispatchEvent 或生产网页脚本注入。未请求屏幕录制、辅助功能或其它新权限。
6. 只在已验证 WebKit 构建启用；缺接口、签名不符、来源无法核验或已有方法被其它组件替换时明确失败，不扩大控制范围。

## 验证结果

- 原生检查：30 项通过，包括异常、嵌套、100 次串行状态范围、2000 次并发范围切换、不向工作线程泄漏状态、错误 ABI/事件拒绝、光标保护前后台策略、窗口查询调用来源隔离。光标策略使用原函数替身，不调用真实系统光标写入。
- 无输入对照组的输入功能检查按预期失败，不会因为命令被调用而假阳性。该组另有一次无输入光标图像变化的观察失败，尚未归因；不将全局图像变化单独解释为本程序改动，原始记录保留。
- 最终 GUI 矩阵：失焦、遮挡、隐藏各 3 轮，共 9 轮 × 25 项 = 225 项检查，全部通过。隐藏是 orderOut，不等于最小化或跨 Space。

| 轮次 | 状态 | 检查 | 外部鼠标事件 | 外部键盘/修饰键计数 | 自身全局鼠标事件 | 拦截光标写入 |
|---|---|---:|---:|---:|---:|---:|
| acceptance-native-pointer-background-1 | background | 25/25 | 245 | 0 | 0 | 18 |
| acceptance-native-pointer-background-2 | background | 25/25 | 299 | 0 | 0 | 18 |
| acceptance-native-pointer-background-3 | background | 25/25 | 23 | 0 | 0 | 18 |
| acceptance-native-pointer-occluded-1 | occluded | 25/25 | 256 | 0 | 0 | 18 |
| acceptance-native-pointer-occluded-2 | occluded | 25/25 | 246 | 0 | 0 | 18 |
| acceptance-native-pointer-occluded-3 | occluded | 25/25 | 275 | 0 | 0 | 18 |
| acceptance-native-pointer-hidden-1 | hidden | 25/25 | 354 | 0 | 0 | 18 |
| acceptance-native-pointer-hidden-2 | hidden | 25/25 | 179 | 0 | 0 | 18 |
| acceptance-native-pointer-hidden-3 | hidden | 25/25 | 203 | 0 | 0 | 18 |

- 静止采样片段：记录到 33 个有实际页面动作、系统位置和光标图像保持稳定的区间；完整明细见 summary JSON。未强迫用户停止使用设备。
- 所有轮次目标 App 均未成为前台、目标窗口均未成为真实 key window；密码框输入未改变该阶段的全局 Secure Input。
- 只读取 HID 事件数量，不记录外部按键内容。外部键盘动作可能合法改变系统光标，不能把“没有鼠标移动”误当成“用户没有任何活动”。
- 诊断页只记录自身输入和原生控件后置条件；键值不写入日志，意外文本被脱敏，失败时不保存页面截图。没有真实账号/订阅或持久 profile。

## 25 项页面与安全检查

- `ready_background`
- `hover`
- `hover_pointer_semantics`
- `hover_exit`
- `click`
- `checkbox_default_action`
- `double_click`
- `text_ascii`
- `backspace`
- `text_unicode`
- `password_without_global_secure_input`
- `range_drag`
- `text_selection_drag`
- `custom_pointer_drag_buttons`
- `held_state_is_process_local`
- `held_state_releases_to_zero`
- `scroll_default_action`
- `pointer_down_buttons_semantics`
- `drag_events_have_held_button`
- `native_mouse_events_trusted`
- `no_unexpected_fixture_input`
- `page_activity_restored`
- `temporary_queries_restored`
- `background_cursor_write_protection`
- `no_global_input_or_activation`

## 测试宿主与此前失败记录

- 使用原仓库 BrowserWebView、BrowserWindowController 及原始配置工厂。测试入口替代正常 Runner 启动，宿主为 LSUIElement/accessory、无 Dock 图标、物理鼠标点击穿透，避免测试窗口截获用户操作；不把它等同正式 Runner UI 验收。
- 首次矩阵有一次光标变化安全检查失败、一次 App 被激活。旧检查未区分外部键盘活动；激活没有唯一归因，未冒充成功或删除记录。随后缩小逻辑查询来源，并隔离测试宿主的 Dock/物理输入，再得到两组全绿矩阵；以本文件的最终矩阵为准。
- 更早的启动超时已采样到 dyld 打开包外测试动态库、未进入 main。当前原型改为静态链接，最终矩阵没有该启动超时。未改 Gatekeeper、TCC 或系统工具链。
- CLI 光标策略测试曾因未初始化 GUI 工厂得到 nil cursor 而异常；生产能力检查已补 nil 拒绝，策略单测改用纯替身，真实工厂由 GUI 验证。
- 正常 SwiftPM 清单仍有宿主 PackageDescription ABI 链接问题；当前 CommandLineTools 中未发现 XCTest.framework。本次严格编译/执行独立原生测试，并直接编译实际模块与应用类，不宣称常规 swift test 或整个工程构建全绿。

## 尚未覆盖/未交付

- AppleScript 正式命令入口、完整 Runner 启动、新标签/新窗口、全屏、指针锁、原生菜单、文件/权限弹窗及真实业务账号。
- 真实中文 IME 连续组词体验、人工前台 Safarier 体验、多显示器、最小化、跨 Space、其它 macOS/WebKit 构建。Unicode 字符输入通过不等于所有 IME 输入行为相同。
- 正常 Runner 原有主动激活启动路径未改；对任意网页的 UI 逃逸/全屏/弹窗还需正式接入时的门禁，不能将本次本地页验证说成所有网站均安全可用。
- 未安装或替换用户现有 App，未提交、推送、合并或发布。源码评审仅由主代理执行。

## 复现

```sh
cd "/Volumes/RC500/dev/safarier"
scripts/verify-background-input.sh --prefix YOUR_UNIQUE_PREFIX --rounds 3
scripts/background-input-probe/run.py --mode stub --label YOUR_UNIQUE_CONTROL --expect-red
scripts/background-input-probe/report.py --prefix YOUR_UNIQUE_PREFIX --control-label YOUR_UNIQUE_CONTROL
```

## 证据

- `.build/mcc-safarier-probe/acceptance-native-pointer-matrix.json`
- `.build/mcc-safarier-probe/acceptance-native-pointer-summary.json`
- `.build/mcc-safarier-probe/runs/<轮次>/report.json` 与 `page.png`
- `.build/mcc-safarier-probe/toolchain/native-input-tests.log`
- 最终可执行文件 SHA-256：`aa94b0ddad25351bc372690f0d88f441c04c9b026a3de6426e92267644bc39d0`
