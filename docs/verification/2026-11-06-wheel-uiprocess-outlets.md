# 2026-11-06 UIProcess wheel 完成出口调查

## 结论与范围

本轮仅基于已有固定源码和只读本机元数据定位。对于原 scoped wheel，已检查的 UI 完成调用点与 C/ObjC 客户端协议**尚未建立覆盖 handled 和 unhandled 的安全被动回调出口**；现有负回调只覆盖未处理事件，不能作为通用 ACK。原路径的安全被动桥尚未建立，wheel 继续 denied；这不是全系统 API 不存在的证明。

`WebPageProxy::wheelEventHandlingCompleted` 先取出一个 coalesced sequence，再尝试取下一待派发事件；没有 next event 只说明此时待派发队列为空，不保证其他已经 in-flight 的 sequence 均已出队。也尚未建立目标原 native wheel 与某个 sequence 完成之间的身份绑定。原 nonce/epoch 是 arm 的关联值，不是 wheel ID。见 `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-uiprocess-outlet-20261106-001/callback-source/findings.md`。

## Native automation 的边界

在所查 `WebAutomationSession.cpp` 中，`m_pendingWheelEventsFlushedCallbacksPerPage` 唯一定位到的注册点是 `simulateWheelInteraction`；它注册回调后调用 `platformSimulateWheelInteraction` 自己发送 wheel。它不是只订阅原 scoped wheel 的接口。源码还存在没有事件在处理时提前返回成功，以及 JavaScript dialog 路径完成 pending 回调的情况；该回调按 page 而非原 native wheel ID 索引。因此不能把回调成功当作原事件的完成证明。

源码中的 automation context 发现会筛选 `controlledByAutomation`；更改该状态会向 WebPage 和 NetworkProcess 传播。但完成调用点直接查询 process pool 的 session，**并不自带 page controlled flag 检查**。端到端接入该页面是否必须设置此标志仍未知，不能暗中启用 session 或更改页面状态。细节见 `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-uiprocess-outlet-20261106-001/callback-source/automation-choice.md`。

## 固定 macOS automation 实现的窗口与焦点行为

固定官方源码 [`WebAutomationSessionMac.mm`](https://github.com/WebKit/WebKit/blob/26695efdefc6076049ec50713a2c4e54b90b4d47/Source/WebKit/UIProcess/Automation/mac/WebAutomationSessionMac.mm) 中，`platformSimulateWheelInteraction`（889–905 行）调用 `sendSynthesizedEventsToPage`；该 helper（80–125 行）对事件执行 `makeKeyAndOrderFront` 和 `page.makeFirstResponder()`，并临时替换 `NSEvent.pressedMouseButtons` 的实现。该固定 macOS 实现与当前不提升窗口、不改变焦点的边界冲突，不能作为当前可直接接受的后端；不请求放宽边界，也不绕过这些步骤。源码与本机二进制等价性未证明，这不是本机行为实测。源文件与证据见 `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-uiprocess-outlet-20261106-001/logging-local/platform-source-note.md` 及 `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-uiprocess-outlet-20261106-001/logging-local/fetch-platform.json`。

## 本机日志与符号元数据

独立进程的限定探针在已打开的系统 WebKit handle/dependency 范围内，未解析到六个候选 C 名称：`WKSetLogChannelToAccumulate`、`WKGetAccumulatedLogs`、`WKContextSetLogChannelToAccumulate`、`WKContextGetAccumulatedLogs`、`WKBundleSetLogChannelToAccumulate`、`WKBundleGetAccumulatedLogs`，以及 channel 数据名 `WebKit2LogWheelEvents`。两个 C++ 符号 `_ZN3WTF26getAndResetAccumulatedLogsEv` 和 `_ZN3WTF20resetAccumulatedLogsEv` 仅被解析，`dladdr` 指向 JavaScriptCore；没有调用或证明其 ABI 可安全使用。

同一探针仅在 `__TEXT,__const` 和 `__TEXT,__cstring` 两节中查找四个精确字符串，均未命中：`WebPageProxy::wheelEventHandlingCompleted - finished handling `、`WebPageProxy::wheelEventHandlingCompleted`、`finished handling `、`WebKit2LogWheelEvents`。这是所测名称、handle 和两节内的限定负证据，不能推断 `LOG_DISABLED=1`、全部日志不可用或全系统 API 不存在。另一次 `dyld_info -exports` 对四个选定 C++ 名称子串未匹配，同样只限该列表和查询范围。原始记录分别为 `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-uiprocess-outlet-20261106-001/logging-local/local-metadata.txt`、`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-uiprocess-outlet-20261106-001/logging-local/execution-evidence.json` 和 `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-uiprocess-outlet-20261106-001/callback-source/export-metadata.json`。

固定源码中的日志点在取出 sequence 后；打印的地址来自按值转换生成的临时 `PlatformWheelEvent` 对象，不是已建立的原 `NSEvent` 身份。日志缺失或超时不是完成；相似事件字段或相似日志也不能证明目标 wheel 完成。本轮没有采集 wheel 运行日志。详见 `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-uiprocess-outlet-20261106-001/logging-local/findings.md`。

## 来源、执行和下一步

所查官方 Safari branch 固定 commit 为 `26695efdefc6076049ec50713a2c4e54b90b4d47`；该源码与本机 WebKit `21624.5.1.11.3` 二进制的等价性未证明。主要官方源：

- [WebPageProxy.cpp](https://github.com/WebKit/WebKit/blob/26695efdefc6076049ec50713a2c4e54b90b4d47/Source/WebKit/UIProcess/WebPageProxy.cpp)（`wheelEventHandlingCompleted`、队列处理）。
- [WebAutomationSession.cpp](https://github.com/WebKit/WebKit/blob/26695efdefc6076049ec50713a2c4e54b90b4d47/Source/WebKit/UIProcess/Automation/WebAutomationSession.cpp)（wheel callback 注册与完成路径）。
- [WebWheelEventCoalescer.cpp](https://github.com/WebKit/WebKit/blob/26695efdefc6076049ec50713a2c4e54b90b4d47/Source/WebKit/Shared/WebWheelEventCoalescer.cpp)（coalescing 和 in-flight sequence）。
- [Assertions.cpp](https://github.com/WebKit/WebKit/blob/26695efdefc6076049ec50713a2c4e54b90b4d47/Source/WTF/wtf/Assertions.cpp)（源码日志累积语义）。

本 stage 原 `fetch.json`、`fetch-more.json`、`fetch-logging.json`、`fetch-event.json`、`fetch-conversion.json` 五份 manifest 的日志下载 SHA 校验为 **27 个条目**，不等同于 27 个不同文件；后续 `fetch-platform.json` 另记录 **3 个条目**，二者分别计数。原 27 项逐项记录见 `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-uiprocess-outlet-20261106-001/logging-local/source-sha-check.json`，获取来源见同目录 `fetch*.json`。本 stage 未做 GUI、输入或私有 ABI 调用，未启用日志 channel、automation session 或 controlled 状态；没有产品代码或身份、签名、inventory、APPL、lease、预算、uncertain 和真实 cleanup 门禁变化。

停止重复观测、monitor、扩大矩阵及 GUI arm/cancel，wheel 继续 denied。后续由用户作产品范围决策：先验收已有后台鼠标、键盘功能并保持 wheel 禁用；或另行评估需要引擎支持的同事件被动完成通知。后者属于新组件／架构评估，尚未经授权，也不保证可行。当前不新增 executor、hook 或 custom engine，不把 native automation 当作已证明可用的后端。
