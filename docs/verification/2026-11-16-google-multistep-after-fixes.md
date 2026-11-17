# 新包 Google 多步骤测试（2026-11-16）

测试未能完成。新包已安装，Test 专用环境成功连接；仅提交一次 Google 搜索导航后返回 `INDETERMINATE_RESULT`，原控制会话随后失效，一次重连也失败。没有取得结果截图，也没有点击搜索结果或执行后续页面操作。

## 包与环境

- 测试环境：既有「Test专用环境」，UUID `8D0DB3A8-F413-4C32-8685-FC769FC7669F`。测试前未运行、没有保存的 session；以 Google 首页启动后有 1 窗口 / 1 标签。没有创建额外标签。
- 构建：testing / release，Swift 包含 `SAFARIER_BOUND_LOCAL_CANDIDATE` 和 `SAFARIER_INTERNAL_TEST_APP`，C 包含 `SAFARIER_BOUND_LOCAL_CANDIDATE`。构建目录 `.build/automation-bound-control-integration-20261104/formal-test-app-20261106-001/packaging/attempt-20261116-201247-667ed2bfdc3c4e4ab2cf5377a6be5fe6`。主 agent 复核源码构建前、后及当前 150 项一致，12 项 pins、签名、namespace、资源与 metadata 检查通过。
- 本轮可交付候选：`.build/google-multistep-after-fixes-20261116/sidecar/Safarier AI.app`；已安装到 `/Users/yingzhang/Applications/Safarier AI.app`，主 agent 独立核对安装包与候选一致。旧安装备份：`/Users/yingzhang/Applications/.safarier-install-backup-c202aff5ad9748208625d7af10be395b.noindex/previous.app`。本轮没有更新 `dist/releases/Safarier AI.app`，该固定路径仍是旧包。
- 控制命令使用新安装包的 `control` CLI、原 `.safarier-control` daemon。所用查询是“小红书笔记指南”，通过一次显式 Google 搜索 URL 提交，没有重复提交。

## 逐步结果

时间为 America/New_York；完整 UTC 时间、命令、退出码、原始 JSON 与 stderr 在私有 `steps.ndjson` 和各步骤 JSON 中。

| 步骤 | 开始时间 | 耗时 | 退出码 | 结果 / requestID |
| --- | --- | ---: | ---: | --- |
| 连接 Test | 07:22:23 | 20.313 秒 | 0 | 成功；`95C08EA1-2C98-49DA-9F77-CEF0444182D1` |
| 提交 Google 搜索导航 | 07:22:56 | 4.689 秒 | 1 | `INDETERMINATE_RESULT`；`7D2C99B3-4D2B-4D7D-979C-24568BCAECD2` |
| 对原连接 observe | 07:23:21 | 0.606 秒 | 1 | `SESSION_EXPIRED`；`55C6E0C0-C03D-492C-B546-97EA4CFF51D1` |
| 对同一环境重连一次 | 07:24:01 | 0.609 秒 | 1 | `BACKEND_UNAVAILABLE`；`97907EE6-ED2B-434E-B464-AF58AACF1D8A` |
| 对原连接 release 一次 | 07:24:20 | 0.614 秒 | 1 | `SESSION_EXPIRED`；`768FBDD4-6F5A-4EC6-BDFA-8BAE3601B0DB`，未取得四项交还确认 |

日志 `.build/google-multistep-after-fixes-20261116/main-search-unified.ndjson` 显示同一导航请求在 07:22:59.681769 的 Runner sink 返回成功、59.832796 handler 返回成功、07:23:00.159689 回执入队；Manager 直到 00.939651 将 endpoint 映射为 `INDETERMINATE_RESULT`。Runner 日志记录 `page_navigation.accepted`、`didStart` 后又出现 `mainExplicitURL` 拒绝（`navigationType=-1`，explicit URL 存在但目标不相同，`sourceURLMatchesCurrent=false`），随后 generation 和 root 通道关闭。该段 bundle 检查记录的 result 均为 0；本次并非20秒预算耗尽或权限查询挂起。证据说明内部导航提交曾成功、后续导航状态与策略发生冲突，并不能确认搜索结果已显示，也不足以确定具体重定向 URL。

因此没有执行点击结果、浏览、进入其他链接、返回和进入下一链接。实际 CLI 没有浏览器历史 back 子命令，且本次未取得页面截图来验证页面内返回入口；没有用显式 navigate 冒充历史返回。

## 恢复与限制

安装前正常退出 My、Manager 和 DSH，保存会话及 metadata；4 个历史 daemon 正常停止，默认 daemon 返回 `SESSION_BUSY`，确认无连接客户端后仅对其原 PID 发送 SIGTERM。这个停止不是 release 成功的证明。新 Manager、My、DSH 和原 5 个 daemon 均已恢复；DSH 新进程监听 `127.0.0.1:61919`。My 保存的 1 窗口 / 6 标签及选中项与退出时逐字段一致；其余原保存会话窗口结构一致。profiles、subscriptions、bookmarks 和 credentials 内容与退出前备份一致。

测试结束时 Test 浏览器进程仍在，保存会话为 1 窗口 / 1 标签；因 release 失败，未确认人工交互已恢复。没有重启该浏览器来绕过错误。私有证据目录 `.build/google-multistep-after-fixes-20261116/` 包含构建、打包、安装、退出/恢复、逐步回执、Runner 日志及主 agent 统一日志；可能包含网页或环境信息，不作公开发布。
