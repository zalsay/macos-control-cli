# 本地候选表单纵切片实施计划

日期：2026-11-05。设计：`/Volumes/RC500/dev/safarier/docs/superpowers/specs/2026-11-05-mcc-safarier-form-slice-design.md`；合同：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/form-slice-20261105/contract.json`。用户已批准目标；main 唯一 review，执行和验收仍按各步派发，不新增审批循环或自动 commit。

### Task 1 — 最小原路径实现与定向 RED/GREEN

- [ ] 沿 `OwnedBrowserAutomationPage.perform` candidate bound 分支，仅扩固定 button／text／scroll 的动作白名单；沿现有 `NativePageInput.perform` 原 click／key／insertText／scroll，不新执行器或通用 DOM 公共接口。文字仅 `native-123`、`中文`；键仅 backspace／left／right、shift=false。
- [ ] 每步原 target、focus、geometry、epoch、context／C／lease 与取消检查前后不减；固定只读页面观察仅返回脱敏值／布尔／trusted 证据，不当身份授权。保留原 absolute 3／45／5／2 秒与 raw cutoff、signed fixture SHA 和 native 活动保护。
- [ ] 为 allowlist／错误焦点／失效 epoch／身份／不确定效果增加最少定向 RED/GREEN；实际 C／Binder／GUI 必须另有真实证据，假对象不算 runtime acceptance。源码写集待 main 派发、worker 不覆盖其他 dirty 文件。

### Task 2 — wheel 完成契约（BLOCKED／denied）

- [ ] 接收 Hooke 的只读 selector／一级来源与本机验证，由 main 审定能否复用原 scoped 原生 wheel 完成链；不猜 SPI／额外事件，不延长预算、不清 `uncertainDispatch` 或把 mouse fence／页面 scrollTop 当 wheel ACK。
- [ ] 若无法证明原目标上的 wheel 完成及后续原 cleanup 安全，则停止 scroll，记录 unknown／阻塞；不为通过而修改 cleanup 判定、输入框架或引入新 executor。若确需超出原写集／接口，先交 main 决定。

### Task 3 — 主审后一次原链 fixture GUI

- [ ] tools／原宿主的必要扩展由 main 另行派发并纳入源码冻结；随后 main 独立审源码／定向测试、双端签名与 exact namespace／pins、实际 sender 和独占 root，再明确派发 GUI。false-preflight、同一 literal AppleScript 发送宿主与 count==1 不变，不用代理 sender。不得对旧 session／失败动作重试，不触发授权框。
- [ ] 在新 workspace／ephemeral profile／session 实际 click button、click text、输入／backspace／left-right／中文、经已证明 completion 的 scroll、截图及真实 close；每步保存最少无敏感内容的回执、固定页面效果／trusted 观察与原 owner cleanup 证据。DOM 只读不得替代 native 输入或授权。任何门禁、结果、focus 或 wheel completion 不明即停，不标完整通过。
- [ ] 使用原整包正常构建与 inside-out 签名，输入前后 SHA 一致；无额外 full tests、ASan、release、VM、全局输入、安装或大矩阵。具体 GUI 与 tools 修改均须 main 单独派发，不因本计划自动执行。

### Task 4 — 用户真实参与的独立验收

- [x] **仅本轮固定 fixture、约 25 秒的有限人工参与完成：**2026-11-05 17:44:35–17:45:00（Asia/Shanghai）`form-a-human-001` 自动链 exit 0，用户事后反馈“没有中断”。不模拟人、不记录其他 App 键入内容；不能将此扩大为所有干扰项逐项通过、长期／完整 G1／G5 或 shipping 通过。自动证据：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/form-slice-20261105/human-concurrent-20261105-001/main-result.json`；运行：`/Users/yingzhang/safarier-bound-control-formaslot-20261105-e199b92a1fe6403fabc8d216a02e7062/form-a-human-001/`。

**历史：Phase A 执行注记（2026-11-05）：**当时计划先按 main 派发完成固定 click／普通文字／三个无 shift 页面键、截图与真实 close；wheel 继续拒绝且不更改不确定标记／cleanup。原全部表单目标与 wheel task 仍未完成；native key 返回不证明 key queue fence，人工并发尚未执行。

**Phase A 实际结果（2026-11-05）：**固定序列、页面额外只读效果、截图与真实 close 在一次新 session 中完成，host `form_a_smoke_complete`、exit 0；证据见 `/Volumes/RC500/dev/safarier/docs/verification/2026-11-05-form-slice-phase-a.md`。该自动结果本身未完成包含 wheel 的原 Task 2／3；其记录时人工并发尚待派发。后续上述 Task 4 仅本轮固定 fixture 有限人工参与已执行，wheel 仍 BLOCKED／denied，不能用硬件计数代替人工反馈。任意文本／站点、IME、完整 key／wheel queue ACK、G1／G5、shipping 不宣称通过。

**Pointer 后续自动证据（2026-11-05）：**`pointer-human-001` exit 0，原鼠标 sequence 1–5、buttons 0／0／1／1／0；截图在 heldMove 前，仅核验绿色 hover，不证明后续任意 DOM drag／drop。用户在该轮结束后原话反馈“没有中断”，仅覆盖 2026-11-05 17:55:24–17:55:44（Asia/Shanghai）的 `pointer-human-001`，不代表各项症状单独肯定或测得持续输入；前一 form-a 的反馈未被继承。反馈收据：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/form-slice-20261105/pointer-human-20261105-001/user-feedback-001.json`；历史 main-result 记录时为 PENDING，未改写。wheel 新只读调查未建立 owned 页面原 scoped wheel 安全完成桥，monitor 符号未调用；Task 2／含 wheel 的 Task 3 仍 BLOCKED／未完成。详见 `/Volumes/RC500/dev/safarier/docs/verification/2026-11-05-form-slice-phase-a.md`。

## 历史：滚轮原链调查与当时的下一授权边界（2026-11-05）

现有链未证明可达的 UIProcess wheel ACK 桥：公开 main 的 wheel completion C 声明受非 Apple 条件、相关实现受 feature 条件限制，不能当作本机可用；本机 UIProcess 限定 exports／metadata 未发现新桥，但不是 API 穷举。公开 main 与相近 Safari branch 均未证明与本机二进制等价。WebProcess monitor 的 deferral／phase callback 与 UIProcess 原事件队列完成之间尚无已证 happens-before；不能清 `uncertainDispatch` 或改变 cleanup，wheel 继续 **BLOCKED／denied**，不开放 wheel GUI。

当时建议用户**单独批准**仅观察的 WebProcess monitor 最小探针；当时该新增组件尚未批准或证明可行。新 bundle 须签名及精确 inventory／code／resource pin，绑定原 owned page／WebProcess；nonce／epoch 仅用于关联而非身份根，还须证明 arm-before-event、one-shot／timeout／late callback 生命周期及真实 cleanup。不新增输入 executor、额外 wheel、automation session、global input 或 PID fallback；若 UIProcess 原事件 ACK 仍未证，回调只能作 observation，不能升级为 ACK／`cleaned=true`。

证据：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-completion-20261105-001/source/findings.md`；`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-completion-20261105-001/local/findings.json`。

**后续状态：**用户已批准该仅观察探针，main 已审实现、签名与 pin；一次无输入 GUI 的 page-scoped arm／cancel 和真实 cleanup 已完成。monitor 注销与 UIProcess wheel ACK 仍未证明，wheel 保持 denied；不新增人工验收结论。详见 `/Volumes/RC500/dev/safarier/docs/verification/2026-11-05-wheel-observer-probe.md`。
