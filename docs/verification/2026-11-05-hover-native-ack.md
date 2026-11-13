# 本地候选 hover native ACK 验证记录

日期：2026-11-05（Asia/Shanghai）。范围为独立候选、固定本地 fixture 与原 Binder／AppleScript／native 链，不是发布验收。

## RED、无效试验与精确撤回

- 诊断候选中 capabilities／openSession／getState 成功，scoped native dispatch 和原 pending-mouse completion 注册均 status 0，tracking owner 为 1；原 mouse completion 在 **3009 ms** 等待内未到达，返回 timeout 并映射为 `INDETERMINATE_RESULT`。该动作的副作用未知，不能重发原 session。
- 随后受控 AppKit event-loop 试验仍在 **3001 ms** timeout，callback 在 **3010 ms** 才出现，可能由关闭时 flush 导致；不能将迟到回调当作按时 ACK。此试验未解决问题。`RunnerMain.swift` 与 `BrowserSession.swift` 两处试验修改已分别核对原 after SHA 后精确撤回到 hover baseline；五个诊断文件保留，失败 App、root 和日志未删除。

## 机制、候选与边界

公开 WebKit main 的 [WebPage.cpp](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/WebProcess/WebPage/WebPage.cpp) 中，无按钮（buttons=0）的 hover mousemove 的回复被延迟到 rendering update 末尾；`finalizeRenderingUpdate` 与 close 可 flush 延迟回复。[WebPageProxy.cpp](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebPageProxy.cpp) 的 presentation 更新路径使用确保绘制的异步请求；[WKWebView.mm](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebView.mm) 提供相应入口。公开 main **不等于本机 WebKit 二进制逐字源码**；这一机制与实测 A/B 结果相符，但不能单凭公开源码证明本机内部每一执行细节。本机 WebKit `21624.5.1.11.3` 的 `_doAfterNextPresentationUpdate:` selector 存在且类型为 `v24@0:8@?16`，已由独立 CLI 检验。

候选仅在原 `NativePageInput.drain` 加入 13 行 candidate-bound presentation 请求：原 3 秒 deadline 已计算后、原等待前，通过原 SFR bridge 请求下一次 presentation 更新；失败沿原 uncertain／error 关闭。presentation callback 仅诊断，**只有原 pending-mouse completion callback 能标记 completed**。原 3 秒／5 秒预算、身份、lease、target、C／headers 和回执门禁不变；没有额外鼠标或 DOM 事件、窗口可见／激活更改、全局输入或 PID 路由 fallback。

## 两次新 session 实际结果

| 证据 | hover-render-001 | hover-render-002 |
| --- | --- | --- |
| 原 mouse completion | 59 ms | 1 ms |
| presentation callback | 64 ms | 8 ms |
| fixture PNG | Hover target 绿色，主 Agent 核图 | 与首轮字节一致，主 Agent 已核验 |
| pointer 回执 | sequence 1–5；buttons 0、0、1、1、0 | sequence 1–5；buttons 0、0、1、1、0 |
| closeSession／整体 | host `protocolFailure`；exit 1 | host `protocolFailure`；exit 1 |
| owned Manager／Runner | Manager 已观察退出 status 15；Runner 独立退出未知 | Manager 已观察退出 status 15；Runner 独立退出未知 |

两次 capabilities、openSession、getState、hover、截图以及后续 drag down／held move／up 的回执均成功；最后 buttons 为 0。两张真实截图 SHA-256 均为 `e1cc78d11e506fc02921aa8d2d9f6ede43c952a62daaa99b7637eed8d2eb5e54`。这些记录支持候选跨过原 hover ACK 阻塞，**不代表完整 GUI、G1／G5、shipping 或人工并发键鼠长期不受干扰已验收**。

## 历史：当时未完成的 close 证明

`AutomationManager.startClose` 当前构造 `CleanupReceipt(cleaned:false, terminatedOwnedRunner:observed)`；该值没有证明 native 页面／store cleanup。两次 close 的外层有 `ok`，但 host 原 `receipt.cleaned` 门禁随后失败，故整体均 exit 1；不得篡改为 true、放宽 host 或把 Runner 服务返回推断成独立退出。native cleanup 证据及结果的真实传递是下一阶段单独工作，本轮不修改其语义。

## 后续：固定 fixture 的 close proof 已完成

后续 raw-cutoff 候选两次原 smoke 均 exit 0，Runner page／store 真实 proof 在 863／900 ms 被 Manager 接受，最终 `cleaned=true`、`terminatedOwnedRunner=true`；上节两次旧失败保持原样。详见 `/Volumes/RC500/dev/safarier/docs/verification/2026-11-05-close-session-proof.md`。这仅是本地 candidate 固定 fixture 闭环，不代表完整 G1／G5、shipping 或长期人工并发键鼠验收。

## 证据

- RED 主 Agent 复核：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/hover-20261105/main-diagnostic-runtime-red-001.json`
- 无效 event-loop 撤回收据：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/hover-20261105/event-loop-fix-001/revert-001/result.json`
- render fix before／after／diff：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/hover-20261105/render-ack-fix-001/`
- 第一轮主 Agent 运行复核：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/hover-20261105/main-render-runtime-review-001.json`
- 第二轮主 Agent 运行复核：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/hover-20261105/main-render-runtime-review-002.json`
- 两轮外层记录：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/hover-20261105/render-runtime-001/runtime-001/`、`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/hover-20261105/render-runtime-001/runtime-002/`
- 两轮自身 Manager／Runner 日志与 PNG：`/Users/yingzhang/safarier-bound-control-renderfix-20261105-05404e6e57a4417b9a8df1c01c1acaab/hover-render-001/`、`/Users/yingzhang/safarier-bound-control-renderfix-20261105-05404e6e57a4417b9a8df1c01c1acaab/hover-render-002/`。
