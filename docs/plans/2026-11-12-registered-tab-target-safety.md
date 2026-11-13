# 已注册 Runner 的多标签目标：离线设计

当前状态：已接入仅限本地 candidate 的单标签组候选；真实 Binder、native 输入与 GUI 清理闭环仍待验证。多窗口组或身份不明确时拒绝。

2026-11-12：隔离 AppKit 测试验证选中项、成员及 overview 的 KVO，单向失效、旧代回调停止和原租约还原；同组另一测试窗口的 manual、mouse ignore、tabbing 属性未变。候选已接入原注册 Runner，隔离测试覆盖选择、撤销和模拟未启动／不确定输入的清理；测试没有证明真实 Binder、WebKit native 输入排空或多标签网页控制的清理闭环。

## 目标选择

- 只考虑已认证 registered Runner 自己的 `BrowserSession.openControllers`，将 controller 按确切 `NSWindowTabGroup` 对象归组；单独窗口自成一组。组内要求 `selectedWindow` 精确对应且仅对应一个仍归该 session 的 controller、window 和 webView。
- 多窗口组必须有可证明的唯一用户目标。可研究 session 内记录的最近用户主窗口及其生命周期；仅凭 `frontmostController` 的最后一个 controller 回退、数组顺序、PID、锁或全局发现不能确定用户目标。证据缺失、冲突、overview 显示或目标不可见时拒绝。
- 将确切 controller、window、webView、tab group、选中窗口和现有 windowID/pageID、控制 generation 一起绑定；不切换标签、不重新排序、不拆分窗口，也不枚举或接管其他进程。

## 失效和清理

- `NSWindowTabGroup.selectedWindow`、`windows` 及 `overviewVisible` 的 AppKit 头文件标明支持 KVO。研究在创建控制代次前订阅，并在订阅后再次核对完整快照，避免订阅间隙；任何选择变化、成员变化、overview、目标丢失或窗口关系改变均应不可逆地撤销该代次，切回原标签不能复活。
- 观察回调应与目标动作序列在主线程串行，先封闭后续派发，再走现有 context closing、输入 drain 和借用窗口清理。动作前后和每个 native 派发前仍需校验同一对象、generation、窗口几何与授权；观察本身不替代原身份和输入证明。
- 停止监控与清理完成须有明确生命周期：旧代的迟到回调不能影响新代；cleanup 必须对原窗口和输入对象独立执行，不能因选中项变化改用另一标签。若对象丢失或无法证明 drain 和还原，保持原有失败关闭，不声称 cleaned。
- 现有 `RegisteredPresentationLease` 修改整个应用的 activation policy 和目标 window 的 tabbingMode，现有 session 背景策略也影响同进程其他窗口。必须先证明这些变化不会干扰其他标签／窗口，并证明目标发生变化后仍能恢复原租约；不能只删除 `controllers.count == 1` 或单标签检查。

## 验证条件

先用无 GUI 状态机验证唯一选择、无目标和多组歧义、切换后再切回、组成员变化、目标丢失、迟到回调与代次隔离。状态机通过不等于 AppKit 回调或 native cleanup 已证明。

在隔离 fixture 及经协调的 GUI 条件下，分别验证真实 tab group 的 KVO 顺序与观察取消、切换／拆分／关闭期间的输入禁止与 drain、目标和其他标签的原窗口关系及焦点、用户页面保留和可见还原；每个结果须用原 Runner 身份和 cleanup 回执核对。缺失任一关键证明时继续拒绝多标签接入。
