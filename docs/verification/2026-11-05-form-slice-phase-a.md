# 固定 fixture 表单 Phase A 验证记录

日期：2026-11-05（Asia/Shanghai）。结论仅覆盖 local candidate 固定序列：button／text click、固定普通文字、backspace／left／right、截图和真实 close；**不是完整 form slice 或发布验收**。

## 构建与有限测试

本轮从 350 文件 before 基线到 main 冻结的 354 文件清单；纯动作分类先有 button RED，后 8 个分类 case GREEN，仅验证 policy，不是 Binder、焦点或真实输入验收。正常 candidate 构建 98 项输入 before／after 一致、inside-out 双签；新 sender SHA-256 为 `3a8ecfa6ae2f846bae7556cd34386fff6f12b1b88e6cce5d57c1bb47255725a1`，其嵌入 Info 节和产物由 main 独立核验。

首次 `form-a-001` 在原 `BoundRunnerServiceSlot` 静态白名单处以 `UI_POLICY_UNAVAILABLE` 拒绝首个 click，未到 Page，故没有 `FORM_DIAG`；其失败 App、root 与日志保留。将该 Slot 对齐为使用同一精确 Policy 分类、保留 Page 实际 held／焦点／序列检查后，在新 root／profile／session 执行 `form-a-slot-001`，整体 exit 0，host 记录 `form_a_smoke_complete`。

## 实际固定序列

| 操作 | native sequence | valueCode | selection | textActive |
| --- | ---: | ---: | ---: | --- |
| clickButton | 1 | 0 | 0 | false |
| clickText | 2 | 0 | 0 | true |
| insertASCII | 3 | 1 | 10 | true |
| backspace | 4 | 2 | 9 | true |
| left | 5 | 2 | 8 | true |
| right | 6 | 2 | 9 | true |
| insertChinese | 7 | 3 | 11 | true |

七条 native 回执的 buttons 均为 0、viewVersion 均为 1。`FORM_DIAG` 分别记录了目标 trusted click／focus／input／keydown／keyup 计数；main 实际核图确认受控 `form.png` 中 `native-12中文` 与末尾 caret 可见。固定页面只读 JS 是额外焦点／效果观察，**不是 DOM 输入，也不是身份根**；native key 返回不是独立 key queue ACK。没有宣称完整 key／wheel queue ACK。

真实 close 中 Runner 日志 `destroyed=true`、`storeCleaned=true`、删除 1、保留 0、目录移除；main 只读核对 artifact base 为空。Manager receipt 为 `cleaned=true`、`terminatedOwnedRunner=true`；Host 持有的 Manager 退出 status 15。原 caller／Binder／typed Core、role pin、权限／路由、3／45／5／2 秒与 raw cutoff、`uncertainDispatch`、cleaned 门禁及 fixture SHA 均保持；fixture SHA-256 `45f599bd8d943192d3f93045559a825b8922f5b2df8106393fc896394355edc1`。

## Pointer 有限并发运行：本轮用户反馈

2026-11-05 17:55:24–17:55:44（Asia/Shanghai），新 session `pointer-human-001` 的 host／外层 exit 0；原 mouse completion 有记录，sequence **1–5**、buttons **0、0、1、1、0**。main 核图确认 hover target 为绿色；**PNG 截于 heldMove 之前，只证明当时 hover，不证明之后任意 DOM drag／drop 效果**。真实 cleanup proof 在 1083 ms 被接受，Runner 页面／store 清理及 artifact base 为空经 main 核对；最终 `cleaned=true`、`terminatedOwnedRunner=true`，原 Manager 退出 status 15。

用户在该轮结束后原话反馈 **“没有中断”**，仅覆盖 2026-11-05 17:55:24–17:55:44（Asia/Shanghai）的 `pointer-human-001`；该反馈单独追加于 `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/form-slice-20261105/pointer-human-20261105-001/user-feedback-001.json`，不是继承前一 form-a 反馈。不能扩大为各项症状单独肯定、测得持续输入、长期不干扰、任意站点／拖放或完整 G1／G5／shipping。main 的历史复核在用户反馈前记录为 PENDING，保持原样。

## Wheel 后续只读技术证据

本机已确认存在 `_webView:didNotHandleWheelEvent:` 的可选协议声明；公开 WebKit main 的调用点只覆盖未处理事件。声明存在不证明本轮收到回调；`_webViewDidScroll:` 也不等于原生 wheel 队列完成。测试 monitor 符号存在，但没有已建立的、适用于现有 owned 页面和原 scoped 事件的安全完成桥。本轮只读检查未调用这些符号，也未增加执行器。main 对公开 WebKit main 的源码观察不证明其与本机二进制逐字相同；wheel 仍 **BLOCKED／denied**，不清 `uncertainDispatch` 或放宽 cleanup。

## 尚未完成与证据

**Wheel BLOCKED／denied：**本机 `WKWebView` 固定 selector 定向检查未发现所测的独立 wheel／scroll 和 keyboard／key pending completion；presentation selector 存在不等于 wheel／key 完成。不可清 `uncertainDispatch`、把 mouse fence／DOM 变化伪作 wheel ACK 或放宽 cleanup。该定向检查不证明不存在其他所有可能 API。

**本轮有限人工参与：**2026-11-05 17:44:35–17:45:00（Asia/Shanghai），运行前邀请用户在另一 App 正常键鼠操作；结束后用户原话反馈 **“没有中断”**。main 复核本轮 7 个动作、页面效果、截图及真实 close，host／外层 exit 0；Runner 记录页面销毁、store 清理、删除 1／保留 0／目录移除，Manager receipt `cleaned=true`、`terminatedOwnedRunner=true`，原 Manager 退出 status 15。自动结果与用户反馈是两类证据；main-result 记录时人工反馈尚待提供，不将其 PENDING 追溯改写。

这仅是本轮受控固定 fixture 的有限反馈，不能扩大为所有干扰项均已逐项问答通过、长期键鼠不干扰、完整 G1／G5 或 shipping 验收；任意文本／站点、IME 与 wheel 仍未覆盖。未模拟人、未记录其他 App 的键入内容，也不能以硬件计数冒充人工证明。

| 证据 | 位置 |
| --- | --- |
| 人工并发运行／main 自动证据复核（复核时人工反馈尚待提供） | `/Users/yingzhang/safarier-bound-control-formaslot-20261105-e199b92a1fe6403fabc8d216a02e7062/form-a-human-001/`；`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/form-slice-20261105/human-concurrent-20261105-001/main-result.json` |
| pointer 自动证据（历史复核时人工反馈 PENDING） | `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/form-slice-20261105/pointer-human-20261105-001/main-result.json`；`/Users/yingzhang/safarier-bound-control-formaslot-20261105-e199b92a1fe6403fabc8d216a02e7062/pointer-human-001/` |
| pointer 后续用户原话反馈 | `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/form-slice-20261105/pointer-human-20261105-001/user-feedback-001.json` |
| pointer hover PNG（heldMove 前） | `/Users/yingzhang/safarier-bound-control-formaslot-20261105-e199b92a1fe6403fabc8d216a02e7062/pointer-human-001/results/hover.png` |
| 前一 form-a 用户反馈（不覆盖 pointer） | `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/form-slice-20261105/human-concurrent-20261105-001/user-feedback-001.json` |
| wheel 新只读技术证据 | `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/form-slice-20261105/wheel-next-20261105-001/findings.json` |
| main 独立运行复核 | `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/form-slice-20261105/main-runtime-review-001.json` |
| 真实截图及 SHA | `/Users/yingzhang/safarier-bound-control-formaslot-20261105-e199b92a1fe6403fabc8d216a02e7062/form-a-slot-001/results/form.png`；`0ddc167072c4466a3ed0970b1e313731db0a05e105a1f2322683b7a9a7439442` |
| wheel／key selector 定向证据 | `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/form-slice-20261105/worker-native-evidence/execute.stdout` |
| policy RED／8 GREEN | `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/form-slice-20261105/worker-policy-red-001/`；`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/form-slice-20261105/worker-policy-green-001/` |
| 源码／产物与 sender 独立复核 | `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/form-slice-20261105/main-source-review-002.json`；`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/form-slice-20261105/main-artifact-review-002/result.json`；`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/form-slice-20261105/main-slot-artifact-review-001/result.json` |
| 真实失败及成功 session | `/Users/yingzhang/safarier-bound-control-forma-20261105-55c9a211c76242bfa755dab4fa43f982/form-a-001/`；`/Users/yingzhang/safarier-bound-control-formaslot-20261105-e199b92a1fe6403fabc8d216a02e7062/form-a-slot-001/` |

## 历史：滚轮原链调查与当时的下一授权边界（2026-11-05）

现有链未证明可达的 UIProcess wheel ACK 桥：公开 main 的 wheel completion C 声明受非 Apple 条件、相关实现受 feature 条件限制，不能当作本机可用；本机 UIProcess 限定 exports／metadata 未发现新桥，但不是 API 穷举。公开 main 与相近 Safari branch 均未证明与本机二进制等价。WebProcess monitor 的 deferral／phase callback 与 UIProcess 原事件队列完成之间尚无已证 happens-before；不能清 `uncertainDispatch` 或改变 cleanup，wheel 继续 **BLOCKED／denied**，不开放 wheel GUI。

当时建议用户**单独批准**仅观察的 WebProcess monitor 最小探针；当时该新增组件尚未批准或证明可行。新 bundle 须签名及精确 inventory／code／resource pin，绑定原 owned page／WebProcess；nonce／epoch 仅用于关联而非身份根，还须证明 arm-before-event、one-shot／timeout／late callback 生命周期及真实 cleanup。不新增输入 executor、额外 wheel、automation session、global input 或 PID fallback；若 UIProcess 原事件 ACK 仍未证，回调只能作 observation，不能升级为 ACK／`cleaned=true`。

证据：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-completion-20261105-001/source/findings.md`；`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-completion-20261105-001/local/findings.json`。

**后续状态：**用户已批准该仅观察探针，main 已审实现、签名与 pin；一次无输入 GUI 的 page-scoped arm／cancel 和真实 cleanup 已完成。monitor 注销与 UIProcess wheel ACK 仍未证明，wheel 保持 denied；不新增人工验收结论。详见 `/Volumes/RC500/dev/safarier/docs/verification/2026-11-05-wheel-observer-probe.md`。
