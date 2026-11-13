# 固定候选 wheel observer 探针计划

以 `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-observer-20261105-001/contract.json` 为合同；main 唯一 review，不 commit／安装。

- [x] 已做纯状态／nonce／epoch／重复／迟到／timeout RED/GREEN；不模拟 Binder 或宣称实际身份。
- [x] Terra 冻结 observation-only plugin 源供 main 独审及独立预编译；UI 原 owned page 桥只固定 arm／cancel，单页／单 generation 和安全 callback lifetime，不增加输入 executor。
- [x] Hooke 独占构建脚本／静态 pin／sender；main 核源码、签名、namespace、精确 pin 和 root 后，才明确派发一次只含 capabilities/open/getState/close 的 GUI，false preflight，失败停。
- [x] 记录 loader 局部副作用与实际 arm/cancel/cleanup；不将 monitor 当 ACK，不开放 wheel，不声称完整 G1/G5／shipping。

**实际状态：**plugin、UI bridge 与双宏 App 接入经 main 独审；candidate 构建和一次无输入 GUI 已完成，page-scoped arm／cancel 与真实 cleanup 有证据。公开相近 loader 的局部 NSEvent 行为已披露，本机二进制实际副作用未独立测量；monitor 注销与 wheel ACK 未证，wheel 仍 denied。详见 `/Volumes/RC500/dev/safarier/docs/verification/2026-11-05-wheel-observer-probe.md`。

## 2026-11-06 因果关系调查

固定 Safari 源码显示，UI 回包后仍可能经 UI 滚动线程后处理再返回主线程；现有 monitor 消息未直接观察目标原 wheel 的 coalescer 最终出队。nonce／epoch 关联 arm，不是原 native wheel ID；尚无法建立足够的 happens-before 与同事件完成证据。候选线程次序是否发生或可被排除均未证明，不是本机竞态复现。clear 停止监测并移除 Page 引用，但旧 monitor 可被强引用保留；普通 FIFO 加 echo 不无条件证明 clear 执行或旧 callback 消失。未建立可达、安全的只读查询，重新注册不是查询。继续 wheel denied、保留有界 static process-lifetime context；既有身份、预算、uncertain 和真实 cleanup 门槛不变，本次无新 native API 或代码。详见 `/Volumes/RC500/dev/safarier/docs/verification/2026-11-06-wheel-observer-causality.md`，及 `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-observer-next-20261106-001/ack-source/ui-deferral-followup.md`。

## 2026-11-06 UIProcess 出口收口

已检查的被动 C/ObjC 全结果出口及原 wheel 与 UI 最终出队的绑定仍未建立；coalesced sequence 出队不证明全部 in-flight 已清空，日志与 automation 回调也不能代替原事件 ACK。wheel 继续 denied，既有门禁不变。固定 macOS native automation 源码中的 `makeKeyAndOrderFront`、`makeFirstResponder` 和临时替换 `NSEvent.pressedMouseButtons` 不符合当前窗口／焦点边界，不作为当前可直接接受的后端；源码与本机二进制等价未证。停止重复观测、扩大矩阵和 GUI arm/cancel；由用户决定先验收既有后台鼠标键盘并保持 wheel 禁用，或另行评估需要引擎支持的同事件被动完成通知。新组件／架构评估未经授权，不保证可行；不新增 executor、hook 或 custom engine。详见 `/Volumes/RC500/dev/safarier/docs/verification/2026-11-06-wheel-uiprocess-outlets.md`。
