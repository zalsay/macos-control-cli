# CLI 非活跃窗口显示修复：本轮验收通过

分支：`mcc-safarier`。Terra 执行，主 agent 独立代码复核、测试复跑、包与原始运行证据复核。没有提交或推送。

## 问题与改动

用户确认，原 CLI 虽能读取页面，但仍需点击 Manager 环境启动按钮才看到完整浏览器。首次候选 163425 的 GUI 显示验收失败；`isVisible=true`、CG onscreen 与页面观察成功均不能替代用户可见性证明。

沿原窗口创建及 presentation lease 链路修改。首次 quiet 显示等待 AppKit finished launch；quiet 初次和鉴权 lease 内两处显示调用使用 `orderFrontRegardless()`，手动初次保留 `orderFront(nil)`。Apple 官方说明前者支持非活跃应用跨应用显示，且不改变 key/main 窗口。保留原身份、同对象、按住鼠标、输入未开始、清理与释放校验；没有全局输入、PID 控制路由、激活应用、修改窗口层级或 Space、自动兜底。历史全部失败的 macOS 根因未被证明。

## 候选与安装

候选：`attempt-20261110-171729-6b334eccdd664274ac13928de89811e6`，Release testing。

- 固定更新包：`dist/releases/Safarier AI.app`。
- 安装包：`/Users/yingzhang/Applications/Safarier AI.app`。
- 主 agent 复跑 focused 15 项，0 失败、0 跳过。
- 126 项 source inventory 构建前/后/当前一致；用户 DSH、UI、Logo 改动保留。
- 11 项包内 pins、namespace/metadata/resources、Manager/Browser 严格签名独立通过。

## 真实运行

北京时间 2026-11-10 17:24:08–17:24:24（UTC 09:24:08–09:24:24）。执行宿主为 Codex 工具链；没有执行 Copis/DSH 同宿主复验，没有请求新的 TCC 授权。

由 CLI 打开原视频号环境，没有点击 Manager 启动按钮，没有发送鼠标键盘输入。完成 launch、connect、state、observe、release，保留同一完整浏览器窗口，CG window 2077。

- 首次与 attach 的完整 CG 安全排序元数据：目标之前重叠几何覆盖均为 0；用户随后确认无需点击 Manager 即看到了完整窗口。
- 29 项采样覆盖全部操作，最大采样间隔约 0.599 秒；操作期间前台应用为 Chrome。阶段日志 active/key/main 均 false。
- state 与 release target 一致，`inputReleased`、`artifactsCleaned`、`browserRetained`、`manualInteractionEnabled` 均 true；原截图 artifact 已删除；新 daemon 正常停止。
- 用户实际反馈：“直接看到了完整窗口”；“当时在操作，未发现干扰”。本轮 CLI 窗口显示及并行操作无干扰验收通过；结论仅覆盖上述时段与操作，不扩展为所有场景或 Copis 同宿主验收。

## 保留的限制与失败记录

前轮 17:05 的用户反馈为仍需点击 Manager，未发现干扰；前轮 watcher 没覆盖真实 CLI 时段，不能声称持续前台采样通过。相关失败 receipt 已校正并保留。

更新前旧 daemon 返回 SESSION_BUSY，缺少原 connection，未取得 release/cleaned 证明。按用户授权，验证旧 owned 实例后正常退出 Manager/Browser，对无 AppKit 注册的同一 daemon 仅发一次 SIGTERM；这只是生命周期处置，不是清理成功证明。旧 runtime 与记录保留，新回合的四项证明不回填旧状态。

原始证据：`.build/inactive-order-gui-93757d7f3b264cee95b3c79130935359/`，主复核为 `main-runtime-review.json`。
