# v0.2.0 通用应用窗口验证

日期：2026-10-21；macOS 本机 ARM64。新增 `desktop-control`，保留 Chrome 专用入口。协议主版本仍为1。

## 已实现

- `apps` 只列有合格屏幕窗口的普通应用；`windows --app <bundleId>` 可筛选。
- 窗口元数据增加 appName/bundleId；连接固定窗口ID/PID/bundleId。每次原生窗口查询、截图、激活与输入均保持该身份。
- 通用入口的runtime与环境变量独立；CLI/daemon模式不符时拒绝，包括停止请求。Chrome信封继续省略scope，兼容旧版daemon。
- 截图/OCR、原像素坐标、三秒接管、用户暂停、输入代次、焦点/几何/指针归属复用原实现。
- 控制条通用模式显示应用名与窗口标题，非激活、非键盘窗口；Chrome旧文案继续兼容。
- 原生文件选择暂时只有Chrome适配；其他应用返回FILE_DIALOG_UNSUPPORTED。菜单栏、任意sheet/子窗口不自动扩大控制范围。

## 自动化验证

- `cargo test --locked`：91项通过，包含新模式、应用筛选、固定bundle、身份替换、非法请求拒绝、跨模式停止拒绝、旧Chrome信封兼容与helper启动参数。
- `cargo fmt --check` 与 `git diff --check` 通过。
- `tests/native-smoke.sh`：153项JSONL协议smoke及原有原生BDD通过；新增应用范围BDD验证Chrome默认不扩权、普通应用筛选与缺失/替换身份拒绝。
- `tests/application-toast-smoke.sh`：通用标题、无键盘焦点、标题更新及取消清理通过；未向用户应用投递输入。
- 独立构建和 `tests/standalone-package-smoke.sh` 验证三项可执行文件、双语README、全部源码、文档链接、SHA256及无运行数据。

## 真实应用输入验证

`tests/application-smoke.sh` 创建临时文本文件与Finder目录，只操作本次创建且标题包含唯一标记的窗口：

- TextEdit：只读截图/OCR，使用正文唯一文字中心点击；Cmd+A 后读取到AXTextArea及非零选择长度，ArrowRight 后选择收起；文件内容未修改。
- Finder：只读截图/OCR，按测试文件的独立AX几何换算到同帧原像素点击；Cmd+A 后读取到实际选择。未打开或修改用户文件。
- finally断开、停止自己的daemon并确认running=false，再关闭本次创建的窗口。

这些桌面测试在用户暂停本轮前完成。恢复后存在其他调用方使用的Chrome连接，故未重复占用桌面输入；未以此声称所有应用均已验证。

## Chrome兼容检查

恢复后使用新构建的Chrome入口对正在运行的0.1.11共享daemon执行只读status/windows，均成功；没有停止、断开或修改该连接。Rust及native回归覆盖原Chrome输入路径。没有在其他调用方使用桌面期间新增真实Chrome输入；此前0.1.11隔离坐标验证记录仍为历史结果，不能替代0.2.0的全场景验收。

## 实测发现与修正

1. TextEdit首轮Observe返回WINDOW_UNAVAILABLE。定位到SCK窗口筛选中遗漏的Chrome硬编码；改为与已验证窗口固定的bundleId匹配，仍检查窗口ID、PID、layer和可见性；随后真实截图通过。
2. 后台冷启动TextEdit的首次输入未取得AXWindows。将激活顺序调整为：已有许可/身份/几何校验 → 激活已验证应用 → 查询精确AX窗口 → 原有焦点/指针复核。没有放宽身份、暂停或输入投递保护。
3. 测试原先以模糊文字匹配选中窗口标题里的文件名，导致焦点进入文件名编辑框；不是坐标映射错误。测试改为正文唯一文字，并以实际AX焦点/选择验证结果，不能只看sent:true。

## 限制

仅验证本机macOS ARM64。其他应用、Intel、多显示器/其他Space、特殊弹窗与安全输入仍需专门验证。输入仍会使用真实鼠标键盘，Spaces不提供独立输入设备。没有新增AX语义操作或虚拟机隔离。分发包为本机ad-hoc签名，没有声称Developer ID公证发布。

## 合并前启动竞争回归

合并后完整复测捕获了已有启动竞争：Unix socket 在 bind 后、chmod 0600 前短暂可见，使启动等待者触发 INSECURE_RUNTIME。现改为在私有临时路径完成权限和非阻塞设置后，再原子重命名发布daemon.sock；仍拒绝不安全路径，不增加绕过或重试例外。确定性BDD覆盖配置期间正式路径不可见、成功后权限0600且可连接、配置失败清理以及临时普通文件不被覆盖；原启动竞争fixture同步使用生产发布路径，并响应慢冷启动下的合法status查询，避免仅监听却不回包造成假超时。
