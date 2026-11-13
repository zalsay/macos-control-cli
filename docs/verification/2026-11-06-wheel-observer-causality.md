# Wheel observer 因果关系调查记录（2026-11-06）

状态：仅固定源码调查与文档收口，交 main 独立审阅；本轮无 GUI、输入、bundle 加载、构建或测试，仅进行源码 SHA 检查。2026-11-05 那一次无输入 GUI、page-scoped arm／cancel 和真实 page／store cleanup 是历史证据，不属于本轮；monitor 注销与 wheel ACK 均未由其证明。

## 同事件与 UI 完成的证据边界

固定 Safari 源码支持：monitor 的 deferral 及 nonce／epoch 不足以证明目标原 native wheel 的 UI coalescer 已完成。nonce／epoch 只关联 arm／generation，不是原 wheel ID；page monitor 的 deferral 状态也不是单事件标识。UI wheel 回包之后仍可派往 UI 滚动线程后处理并返回 UI 主线程，现有 observer 消息并未直接观察目标序列在 coalescer 的最终出队。因而尚不能建立可放行的同事件完成证明或足够的 happens-before（HB）证据。

关于目标 wheel 自身的候选跨线程次序，UI-side deferral 可能影响该次序；现有源码调查既未证明候选次序可发生，也未证明它被排除。补充调查是对早期 counterexample 叙述的必要收窄，不宣称已证竞态反例或 monitor 必然提前。独立归因缺口仍在：arm 的关联值不能标识原 wheel。源码允许或未排除的次序均不是本机实测竞态。

## 停止观测的证据边界

固定源码中 clear 停止 coordinator 监测并移除 Page 对 monitor 的引用，不显式清空旧 monitor 的 callback；deferrer 的强引用可保留旧 monitor。强引用保留不等于证明旧 callback 必定再次触发。clear 是单向处理；即使普通 FIFO 和随后的 page echo，在未独立证明发送、处理、页面与进程身份及相关顺序条件时，也不能无条件认定 clear 已执行，更不能证明旧 callback 消失。

内部 `Page::isMonitoringWheelEvents()` 只反映该 Page 当前引用；尚未建立可达、安全且能证明旧 callback 生命周期的只读查询。重新注册会改变 callback 状态，不是查询；这里不宣称不存在任何其他 API。继续保留有界 static process-lifetime context 与迟到 callback 防护，不能将 void clear、逻辑 cancel 或进程退出当作注销或 cleaned 证明。

## 约束与证据

wheel 保持 denied；原 C 身份、签名、inventory、APPL、lease、3-45-5-2 预算、uncertain 与真实 page／store cleaned 规则均不放宽。本轮不新增 native API 调用或产品代码，不宣称已找到安全 UI hook 或批准新组件。

调查材料（绝对路径）：

- `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-observer-next-20261106-001/stop-source/findings.md`
- `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-observer-next-20261106-001/ack-source/minimal-counterexample.md`：其早期目标事件次序表述以以下补充调查的收窄为准。
- `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-observer-next-20261106-001/ack-source/findings.md`
- `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-observer-next-20261106-001/ack-source/ui-deferral-followup.md`

官方源码固定提交 `26695efdefc6076049ec50713a2c4e54b90b4d47`：[Page.cpp](https://github.com/WebKit/WebKit/blob/26695efdefc6076049ec50713a2c4e54b90b4d47/Source/WebCore/page/Page.cpp)、[WheelEventTestMonitor.h](https://github.com/WebKit/WebKit/blob/26695efdefc6076049ec50713a2c4e54b90b4d47/Source/WebCore/page/WheelEventTestMonitor.h)、[WebPageProxy.cpp](https://github.com/WebKit/WebKit/blob/26695efdefc6076049ec50713a2c4e54b90b4d47/Source/WebKit/UIProcess/WebPageProxy.cpp)、[RemoteLayerTreeEventDispatcher.mm](https://github.com/WebKit/WebKit/blob/26695efdefc6076049ec50713a2c4e54b90b4d47/Source/WebKit/UIProcess/RemoteLayerTree/mac/RemoteLayerTreeEventDispatcher.mm)。固定源码是相近版本，尚未证明与本机 WebKit 21624.5.1.11.3 二进制等价。源码文件 SHA 校验记录见 `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-observer-next-20261106-001/docs-sync/source-sha-check.json`；本记录不替代真实运行验收。
