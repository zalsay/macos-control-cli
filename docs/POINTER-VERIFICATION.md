# v0.1.4 指针遮挡误报排查与修复（2026-10-20）

## 已确认的事实

用户报告 CLI 点击“发表视频”被 `POINTER_OBSCURED` 拒绝，并怀疑 MonitorControl 的遮罩。排查开始时，进程与应用列表中没有正在运行的 MonitorControl，因此不能把本次故障简单归因为该应用仍在拦截输入。

只读窗口元数据显示：Dock 有一个 layer=20、alpha=1、覆盖整屏的绘制窗口（本次窗口 ID 12780），长期排在普通应用前面。原 `verifyPointer` 只看 CGWindowList 的顺序、矩形是否覆盖坐标以及 alpha，大于零就将第一个绘制窗口当作事件接收窗口，因此会拒绝点击。

在不发送任何鼠标键盘事件的前提下临时激活目标 Chrome 窗口 7185，精确焦点与几何检查通过；旧代码仍因 Dock 绘制窗口返回 `POINTER_OBSCURED`（RED）。WindowServer 的只读命中与 AX 命中则指向下层目标 Chrome。这个差异确认了“绘制覆盖不等于输入遮挡”的误判。

MonitorControl 源码的调光窗口采用 `ignoresMouseEvents` 的情况只能作为同类线索，不代表本次现场仍运行着同一遮罩。修复不依赖退出或重启 MonitorControl，也没有修改任何显示器、调光或系统设置。

## 修复方式

- 新增 `PointerTarget.swift`，动态探测 WindowServer 的只读命中接口：`SLSMainConnectionID`、`SLSFindWindowAndOwner`、`SLSConnectionGetPID`。
- 要求实际接收事件的窗口 ID 和 PID 精确等于已授权的 Chrome 窗口；随后独立核对 AX 命中，再复核一次 WindowServer 命中，防止 AX 查询期间新增真实遮挡。
- 查询失败、空窗口/进程、不同窗口或不同 PID 都关闭输入。没有按应用名称、layer、窗口大小或透明度设置豁免。
- 接口符号不可用时回到原有保守 CG 遮挡检查；接口存在但查询失败时不能降级为只相信 AX。
- 仍保留精确前台焦点、窗口几何、取消 generation 及输入串行约束。没有使用裸 Quartz/CGEventPost 绕过校验；原 CLI 最终本来就通过 CGEvent 投递事件，改变调用入口并不能解决真正的输入遮挡。
- Electron 对 `POINTER_OBSCURED` / `POINTER_UNVERIFIED` 映射到既有可恢复输入归属状态 `CHROME_FOCUS_LOST`，同时保留白名单原生码与固定原因，不再误报为组件损坏，也不透传原始 stderr/输入内容。
- 组件版本提升为 0.1.4，协议主版本保持 1；版本锁和发布归档同步更新。

## 回归验证

### 无桌面副作用 BDD

默认 native-smoke 加入指针归属回归，覆盖：两种命中源均匹配、不同进程、同 Chrome 不同窗口、查询失败、空身份、AX 查询期间新增可拦截浮层。所有失败均不发出输入。独立复审指出 SPI 不可用的保守路径必须对已覆盖点但身份缺失的前景窗口直接拒绝，不能跳过后接受下层 Chrome；新增缺少 PID、缺少窗口 ID、身份格式错误的回归先 RED 后 GREEN。既有截图回退、取消、焦点和协议回归保留。

### 显式真实窗口只读回归

`bash tests/pointer-occlusion-smoke.sh <Chrome窗口ID>` 会临时激活选定 Chrome，展示短暂受控测试浮层，结束后在未切换到其他应用时恢复原前台。不会移动鼠标、点击、输入、截图或读取页面业务内容。

本机 ARM Mac 的结果：

1. Chrome 前台、Dock 整屏绘制窗口仍置顶：指针校验通过（旧代码 RED，新代码 GREEN）。
2. 目标点上方增加 `ignoresMouseEvents=true` 的测试浮层：校验通过。
3. 同一浮层改为接收鼠标：返回 `POINTER_OBSCURED`，仍拒绝真实遮挡。
4. 收起浮层并等待 WindowServer 确认其退出命中列表后：指针及精确焦点校验恢复。

收起/更改原生窗口状态并非同步完成，测试以只读命中轮询等待窗口服务完成，不凭固定 sleep 假定成功；生产路径仍在状态无法确认时拒绝输入，不自动重放坐标。

### 集成边界

新增两项 Electron BDD 先 RED（原先误映射为 CHROME_HELPER_FAILED），修复后确认保留 pointer 原生码、click 动作与固定原因，不泄露测试原文、不自动重试输入。

此次没有代用户点击“发表视频”、选择文件、上传或发布。只读命中校验成功不等于网页业务点击已经完成，实际页面操作仍需使用新版连接重试并由用户确认结果；没有使用截图代替 Electron UI 验收。

## 兼容性与生效

WindowServer 命中为非公开 SPI，动态能力检查和失败关闭不等于承诺后续 macOS 版本 ABI 不变；Intel 交叉编译也不替代 Intel 实机验证。无法可靠确认实际输入归属时仍拒绝，不盲点。

本机受管安装切换到 v0.1.4 后，旧连接继续固定原版本；先停止当前 Chrome 控制再重新开始，才能使用新版 Helper。具体错误文案属于 Electron 主进程，需包含该改动的应用构建才会显示。不原地修改已签名 Copis.app，也不停止其他 Agent 的 runtime。

根 README/AGENTS 未修改。未发布 COS；其他机器无法仅靠远端 manifest 自动获取本机归档。
