# 本地候选固定 fixture 表单纵切片设计

日期：2026-11-05。用户已批准目标；本文为现有链路的窄实现合同，不代表完整人工并发或发布验收已通过。main 是唯一代码 reviewer，Terra 实现；初始阶段只写设计／计划，后续有限运行见下。

## 目标与实施前现状

沿同一 Safarier.app 的原 static-role Manager／Runner、AppleScript、Binder channel 和 `NativePageInput`，在已固定本地 fixture 上验证 click、普通文字、有限页面键、scroll、截图和真实 close，不增加输入 executor。实施前 `OwnedBrowserAutomationPage.perform` 的 bound 分支仅准许 move/down/up，且有 bound drag／held 限制；现有 `NativePageInput.perform` 已实现 `.click`、`.key`、`.insertText`、`.scroll`，沿原路径扩展 candidate 的精确许可，不解除普通 shipping 门禁。`key`／`type` 依赖 owned window 的 firstResponder 为 webView 子孙；type 使用既有 `NSTextInputClient.insertText`，不是启用 IME。每次仅一次 native 动作，nativeDelivered 本身不是 DOM 效果或 wheel 完成证明。

fixture 为原 `scripts/background-input-probe/fixture.html`，SHA-256 `45f599bd8d943192d3f93045559a825b8922f5b2df8106393fc896394355edc1`；不改 HTML／资源／签名合同。原固定矩形：`#button` (40,40,140,60)、`#text` (40,140,320,40)、`#scroll` (40,330,520,180)，坐标为 viewport points。拟用内部点分别 (100,70)、(100,160)、(220,400)，必须与真实当前 viewport、固定元素 hit target 一致，不得因布局／缩放变动放宽。

## 精确动作与观察

1. 先经原真实控制链创建新 session／读取 viewport；仅 single-click 固定 button，观察原 fixture click 计数及目标 trusted 事件（不成立则记录真实结果并停止）。然后 single-click 固定 text，须同时满足 owned window／webView 原 firstResponder 检查及固定页面当前 activeElement 为 `#text`，并观测真实目标焦点；无焦点即停，不用 DOM focus 修复。
2. 仅对仍为同一固定 text 目标输入 `native-123`，backspace 得到 `native-12`；left、right 均不带 shift，核对 selection／焦点仍符合预期，再插入 `中文` 得到 `native-12中文`。candidate 仅允许该明确序列所需的文字块 `native-123`、`中文` 和 backspace／left／right；不开放任意文本或键。只读观察输出白名单布尔／固定枚举、必要计数与 selection；意外值只报 unexpected，不记录任意实际文字。保留 trusted 观察，但不得预先假设 `NSTextInputClient.insertText` 必然生成某种事件；缺少 required 观察不能伪造通过。
3. 仅在 wheel 完成／安全关闭契约经 main 定案后，向固定 `#scroll` 区域发一次受限 delta，并观察 scrollTop 实际变化与目标 trusted wheel 事件；固定截图用于真实可见 fixture 状态。不能仅凭 scrollTop、截图或鼠标 fence 推断 wheel ACK／安全完成。最后走原 closeSession，须真实 page／store cleanup proof 与原 owned exit 结果，不放宽 `cleaned`。

不打开 password、selection、Tab、系统快捷键、shift、任意导航或外部站点；不使用 DOM setter、focus、click、dispatchEvent 或模拟事件。第一轮不使用 IME。两个插入内容是固定 fixture 测试字符串，不是采集人类键入内容。

只读 JS 如确实需要，仅可在 **已验证的原 owned 固定 fixture 页面内**执行固定表达式，读取焦点／白名单值等最小证据；可参考原 fixture `probeSnapshot()`，但不可原样输出 records／坐标／其他输入内容。它只作页面效果／动作前附加条件，绝不成为 caller、Binder、目标、进程或 lease 身份根；不新增任意 JS／通用 DOM 公共命令。若需要新的公开协议／工具入口才能实现，停止交 main 裁定。

## 原门禁与关键阻塞

每个动作及其只读观察前后维持原 context.validate／C self-peer-资源／owned birth／held lease、原 epoch、viewport 与 hidden-window／activity／geometry 检查；异步观察返回后重新检查同一 target、焦点、取消及原绝对 deadline，不能在等待期间替换目标或扩预算。原 3s frame、45s lifetime、5s action、2s cleanup、raw cutoff 与 strict `<=` 均不变；失败按原不确定结果／关闭路径停止，不重新发送动作或清除风险标记。

**Scroll 暂不可宣称安全完成：**当前 `NativePageInput.deliver` 对 `.scrollWheel` 设置 `uncertainDispatch=true`，且 mouse pending fence 不证明 wheel 完成；原 destroy／cleanup 保守语义必须保留。Hooke 此前已只读核实本机原生 wheel completion selector 与一级源码；后续 main 只读调查仍未建立可用的原链完成机制，见下。没有证据则 scroll 阻塞／失败，不调整状态标记、编造 ACK、改 cleanup 门禁或引入未经批准的 SPI／额外 executor。仅页面观察成功不构成安全完成或最终通过。

正常 App／Profile、BundleID／argv、C 和协议、身份／权限／路由、固定 fixture 与原 sender 不变；无 global input、PID fallback、焦点／光标恢复、窗口激活、VM、全量矩阵、安装或 commit。需要 consent 时 ask=false 并停止。

## 验证与人工参与边界

先对新增 allowlist／焦点和失败关闭作少量定向离线验证，不以假 page 或模拟 Binder 宣称真实身份通过；main 复核源码、签名、双角色 pin、root 和 sender 后，明确派发新 workspace／profile／session 的一次固定 fixture GUI。保存原真实回执、白名单只读断言、截图、close proof 与 owned cleanup；任一步失败停止，不自动重试或更换身份。scroll 前提未满足则不能声称纵切片全通过。

人工并发是独立验收：必须由真实用户参与其正常键鼠，并事先明确场景与用户意愿；不模拟人、不记录键入内容、不扫描或操作用户其他应用，不把机器截图或自动动作当人工反馈。未实际执行的范围仍记未验收；本设计不自行授权新的 GUI 或人工测试。

## Phase A（2026-11-05 批准）

先仅实现固定 button／text click、白名单普通文字、backspace／left／right、截图与真实 close；wheel 保持明确拒绝，不改 `uncertainDispatch` 或 cleanup。所有效果依实际焦点／可信事件／白名单状态观察，native key 返回不是 key queue ACK。Phase A 成功也不是完整 form slice；当时 wheel 与真实人工并发尚未验收，后续有限人工运行见下。

## Phase A 实际状态（2026-11-05）

固定 button／text 点击、白名单文字与 backspace／left／right 的一次新 session 已有真实回执、页面额外只读效果／trusted 观察、main 核图和真实 close proof；详见 `/Volumes/RC500/dev/safarier/docs/verification/2026-11-05-form-slice-phase-a.md`。该轮记录时 wheel 为 **BLOCKED／denied**、人工并发尚未执行；后续仅固定 fixture 有限人工参与已执行，wheel 仍阻塞。此结果不覆盖任意文本／站点、IME、独立 key／wheel queue ACK、完整 G1／G5 或 shipping。

## 本轮有限人工参与（2026-11-05）

17:44:35–17:45:00（Asia/Shanghai）的约 25 秒固定 fixture `form-a-human-001` 自动链、截图与真实 close 由 main 复核；用户事后原话反馈“没有中断”。这是本轮有限反馈，不代表所有干扰项逐项问答通过、长期 G1／G5 或 shipping 验收。自动复核时人工反馈尚待提供：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/form-slice-20261105/human-concurrent-20261105-001/main-result.json`；运行：`/Users/yingzhang/safarier-bound-control-formaslot-20261105-e199b92a1fe6403fabc8d216a02e7062/form-a-human-001/`。

## Pointer 与 wheel 后续证据（2026-11-05）

`pointer-human-001` 自动链 exit 0，原鼠标回执 sequence 1–5、buttons 0／0／1／1／0；截图为 heldMove 前绿色 hover，不能证明后续 DOM drag／drop。用户在该轮结束后原话反馈“没有中断”，仅覆盖 2026-11-05 17:55:24–17:55:44（Asia/Shanghai）的 `pointer-human-001`；不代表各项症状单独肯定或测得持续输入，也不能继承 form-a 的用户反馈。反馈收据：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/form-slice-20261105/pointer-human-20261105-001/user-feedback-001.json`；历史 main-result 记录时为 PENDING，未改写。原 owned cleanup 有真实 proof。main 只读 wheel 调查显示未建立既有 scoped 事件／owned 页面安全完成桥，所测 monitor 符号未调用、未新增执行器；公开 main 不等同已验证本机二进制。wheel 仍 **BLOCKED／denied**。见 `/Volumes/RC500/dev/safarier/docs/verification/2026-11-05-form-slice-phase-a.md`。

## 历史：滚轮原链调查与当时的下一授权边界（2026-11-05）

现有链未证明可达的 UIProcess wheel ACK 桥：公开 main 的 wheel completion C 声明受非 Apple 条件、相关实现受 feature 条件限制，不能当作本机可用；本机 UIProcess 限定 exports／metadata 未发现新桥，但不是 API 穷举。公开 main 与相近 Safari branch 均未证明与本机二进制等价。WebProcess monitor 的 deferral／phase callback 与 UIProcess 原事件队列完成之间尚无已证 happens-before；不能清 `uncertainDispatch` 或改变 cleanup，wheel 继续 **BLOCKED／denied**，不开放 wheel GUI。

当时建议用户**单独批准**仅观察的 WebProcess monitor 最小探针；当时该新增组件尚未批准或证明可行。新 bundle 须签名及精确 inventory／code／resource pin，绑定原 owned page／WebProcess；nonce／epoch 仅用于关联而非身份根，还须证明 arm-before-event、one-shot／timeout／late callback 生命周期及真实 cleanup。不新增输入 executor、额外 wheel、automation session、global input 或 PID fallback；若 UIProcess 原事件 ACK 仍未证，回调只能作 observation，不能升级为 ACK／`cleaned=true`。

证据：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-completion-20261105-001/source/findings.md`；`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-completion-20261105-001/local/findings.json`。

**后续状态：**用户已批准该仅观察探针，main 已审实现、签名与 pin；一次无输入 GUI 的 page-scoped arm／cancel 和真实 cleanup 已完成。monitor 注销与 UIProcess wheel ACK 仍未证明，wheel 保持 denied；不新增人工验收结论。详见 `/Volumes/RC500/dev/safarier/docs/verification/2026-11-05-wheel-observer-probe.md`。
