# Wheel observer 无输入探针验证

日期：2026-11-05（Asia/Shanghai）。用户批准新增仅观察组件；本记录仅覆盖独立 candidate 的一次无输入握手和原清理，不是 wheel 完成、输入能力或发布验收。

## 构建与证据层次

纯状态／nonce／epoch／重复／迟到／timeout 和 ASCII wire 定向 RED/GREEN 只验证局部状态，不模拟 Binder 身份。独立签名的 observer 为 BNDL／MH_BUNDLE、精确 6 项 namespace；原 C 在新的内部 0700 根实际验证 inventory、固定哈希、签名和 CDHash（exit 0）。先前外部根的 C gate 拒绝记录保留，未放宽权限门禁。Observer candidate 一次 normal build 输入 107 项前后一致；main 独立核对 364 项源码、Main／Runner／observer 三端签名与 27／16／6 namespace、12 项 artifact pin、root 和新 sender 实际 Mach-O Info／SHA。静态成功不等于实际页面握手或 wheel ACK。

## 唯一一次无输入 GUI

`wheel-observer-001` 于 20:09:41–20:09:53（Asia/Shanghai）执行原 literal AppleScript／Binder 链，**capabilities、openSession、getState、closeSession 全部 ok**；false-preflight，host／外层 exit 0。没有发送 mouse、key、wheel 或截图请求。原 same-BID Manager 唯一路由与 owned Core 往返成立。

实际 page-scoped arm／armed、cancel／cancelled 握手完成，UI client detach 调用成功；plugin 的 registration 返回 true **不保证 monitor callback 将来一定到达**，monitor 注销／回调释放语义未证。捕获的 Runner 日志未见 observed；本轮无输入，无 deferral／callback 是预期，不能推断 callback 永远不发生，更不是 wheel ACK。单 page／generation 的 callback context 仅按已审的有界 process-lifetime 策略保留，不宣称已注销或释放。

Runner 实际 page destroyed／store cleaned 均 true，删除 0、保留 0、目录移除；main 只读核验 artifact base 为空。Manager 在 1087 ms 接受真实 cleanup proof，最终 `cleaned=true`、`terminatedOwnedRunner=true`；原 owned Manager 已观察退出 status 15，Runner exit 由原 owner 单独观察。**进程退出没有替代 page／store cleanup proof。**

## 不覆盖与 loader 边界

wheel 仍 **denied**：monitor 回调不是 UIProcess 原 wheel queue／单事件 ACK，不能据此清 `uncertainDispatch` 或改变 cleanup。无新人工并发验收；先前 form／pointer 两轮用户反馈只覆盖各自原运行。相近公开 WebKit loader 源显示 NSEvent.modifierFlags 在对应 WebProcess 内的局部实现替换，非全局 HID；本机二进制实际副作用未独立测量，不宣称零 mutation。任意站点／输入、完整 G1／G5、shipping 均未验收。

## 证据

- main 源审／实际 GUI 复核：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-observer-20261105-001/main-source-review-001.json`；`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-observer-20261105-001/main-runtime-review-001.json`
- plugin 源／产物与原 C gate：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-observer-20261105-001/main-plugin-source-review.json`；`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-observer-20261105-001/main-plugin-artifact-review/`；`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-observer-20261105-001/packaging/pin-and-gate-002/summary.json`
- candidate 构建、三端及 sender 复核：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-observer-20261105-001/packaging/app-build-run-001/summary.json`；`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-observer-20261105-001/main-app-artifact-review/result.json`；`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-observer-20261105-001/main-host-artifact-review.json`
- 外层 argv／env／exit／时间：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/wheel-observer-20261105-001/gui-run-001/`；本次 host／Manager／Runner 日志：`/Users/yingzhang/safarier-bound-wheelobserver-20261105-89c597a4a0d94d09acc704a046c560af/wheel-observer-001/`。
