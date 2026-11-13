# 固定候选 wheel observer 探针设计

状态：实现已由 main 独审、构建并完成一次无输入 probe GUI；main 唯一审阅。用户批准仅观察，不批准将 monitor 当 wheel ACK。contract：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-observer-20261105-001/contract.json`。

Runner 静态嵌入 `Contents/PlugIns/SafarierWheelObserver.bundle`，BID `sh.safarier.boundcandidate.wheelobserver`，BNDL／MH_BUNDLE，独立签名、精确六项 inventory 与 code/resource pin；Hooke 独占打包和 Core pin。仅双宏 candidate，在原 context／profile／inactive 检验后、唯一 bound WebView 创建前配置，原 fixture、身份和预算不变。

page-scoped 消息仅 arm／armed／observed／cancel／cancelled；nonce／epoch 只做关联，原 Binder／page 身份是授权根。一次 page／generation、原绝对有限 deadline；无 wheel 时无 deferral／callback 是预期，不等待或制造事件。cancelled 为逻辑状态而非释放证明；迟到 callback 不得访问释放对象，无法证明注销时最多保留一个 process-lifetime 上下文。失败沿原关闭；原 cleanup／uncertain 不变。

仅 capabilities/open/getState/close 的隔离 GUI 须 main 独立审核后派发；不执行 pointer、key、wheel 或截图。Monitor observed 不是 UIProcess 原 wheel queue ACK，wheel 仍 denied。公开相近 WebKit loader 源有 **WebProcess 内** NSEvent.modifierFlags 局部实现替换；非全局 HID，本机二进制行为尚未确认，本探针不自加 swizzle／restore，也不宣称零 mutation 或用户长期无干扰。

## 本轮实现状态

plugin 源已由 main 独审冻结；纯状态／wire 定向 RED/GREEN 完成。UI 桥使用签名检查的 page getter、原系统 WebKit 符号和原上下文；成功路径逻辑 cancel 后移除 UI client，monitor 注销未证实，plugin 与 clientInfo 仅保留至进程退出。失败路径废弃本地 callback、标记 UI detach 未确认并沿原 page／store 清理，不能把失败当作注销证明。测试 monitor 启用会改变该 WebProcess 的监测状态；未发送 wheel，也不改变原 `uncertainDispatch`／cleanup。

历史：当时仅做纯测试、无对象 metadata／定向语法与类型检查，尚未构建完整 App 或执行 probe GUI；本机 loader 局部 NSEvent 实际副作用仍未独立测量。后续已完成一次无输入 page-scoped arm／cancel GUI 与真实 cleanup；monitor 注销未证，wheel ACK 未证明。详见 `/Volumes/RC500/dev/safarier/docs/verification/2026-11-05-wheel-observer-probe.md`。

## 2026-11-06 因果关系调查

固定 Safari 源码显示，UI 回包后仍可能经 UI 滚动线程后处理再返回主线程；现有 monitor 消息未直接观察目标原 wheel 的 coalescer 最终出队。nonce／epoch 关联 arm，不是原 native wheel ID；尚无法建立足够的 happens-before 与同事件完成证据。候选线程次序是否发生或可被排除均未证明，不是本机竞态复现。clear 停止监测并移除 Page 引用，但旧 monitor 可被强引用保留；普通 FIFO 加 echo 不无条件证明 clear 执行或旧 callback 消失。未建立可达、安全的只读查询，重新注册不是查询。继续 wheel denied、保留有界 static process-lifetime context；既有身份、预算、uncertain 和真实 cleanup 门槛不变，本次无新 native API 或代码。详见 `/Volumes/RC500/dev/safarier/docs/verification/2026-11-06-wheel-observer-causality.md`，及 `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-observer-next-20261106-001/ack-source/ui-deferral-followup.md`。
