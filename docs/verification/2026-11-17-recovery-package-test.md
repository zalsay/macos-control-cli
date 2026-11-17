# 请求恢复修复后的打包与 Test 验证

日期：2026-11-17。分支 `mcc-safarier`，基线 `5455752` 加工作区修复；未提交、未推送。用户本轮授权重新构建、安装并启动测试。没有运行全量回归，代码由主 agent 复核。

## 安装与本轮额外修复

最终 testing/release 包：
`.build/recovery-package-20261117/packaging/attempt-20261117-170713-35a5c54e636d4f14b26ee3841f8fc8ca/Safarier AI.app`。

启用原有 `SAFARIER_BOUND_LOCAL_CANDIDATE`、`SAFARIER_INTERNAL_TEST_APP`。150 项源码摘要在构建前、后及安装前一致；12 项 pin、签名、资源与 namespace 检查通过。使用原事务安装器替换 `/Users/yingzhang/Applications/Safarier AI.app`，旧包路径见本地 `install-final.json`。

真实安装测试发现了此前原生 sender fixture 没有覆盖的 LaunchServices 行为：运行 sfa CLI 时，系统同时列出已完成启动的 Manager 与未完成 GUI 启动的 CLI。旧发送端按 bundle ID 记录总数判定唯一性，导致 `phase=route` 拒绝。修正发送端两处筛选后，授权和 launch 成功；随后 connect 仍报 `RUNNER_EXITED`，Runner 日志实际已接收并回复。Manager 的连接证明另有同类注册总数检查，需同步筛选。最终三处均只计已完成 GUI 启动、未终止的应用；没有新增路由或移除真实 Manager 歧义、身份、PSN、权限及回包核验。

初始失败：`09-connect` request `6EA2E252-093F-4ED7-81CE-12B70EAD7D59`，3.302 秒，`RUNNER_EXITED`。这不是浏览器退出的证明。该次失败后 `10-stop-after-failed-connect` 成功。修正后的真实 connect、release、重连证明见下表。

## 实际安装版 Test 控制链路

Test profile：`8D0DB3A8-F413-4C32-8685-FC769FC7669F`。
证据目录：`.build/recovery-package-20261117/main/`；每条命令记录耗时、退出码、原始 JSON，observe 的 PNG 在释放前独立复制。

| 操作 | 耗时 | 结果 |
| --- | ---: | --- |
| daemon 共存时启动 Test | 0.370 秒 | `13-launch-test` 成功 |
| 连接 Test | 3.435 秒 | `14-connect` 成功 |
| 初次 observe | 1.756 秒 | 显示恢复的飞书文章 |
| Google 搜索“小红书笔记指南”导航 | 0.634 秒 | 仅提交一次，随后截图确认真实结果页 |
| 点击飞书结果 | 0.616 秒 | 投递成功；截图显示 docs.feishu.cn TLS 错误，不算正文成功 |
| Backspace 返回 | 0.636 秒 | 截图确认回到同一 Google 结果 |
| 点击另一个 135editor 结果 | 0.617 秒 | 投递成功；两次截图仍空白，state 为 loading:true，未声称正文加载成功 |
| 从加载页 Backspace 返回 | 0.632 秒 | 截图确认回到 Google，无重复搜索 |
| PageDown | 0.570 秒 | 截图确认翻到结果页底部 |
| PageUp | 0.652 秒 | 截图确认向上翻页 |
| release | 0.801 秒 | 四项交还标志全部 true |
| daemon stop / start | 0.382 / 0.529 秒 | 均成功 |
| 重连同一 Test | 7.788 秒 | 成功，profile/runner/window/page 和 URL 与释放前一致 |
| 再次 release | 1.178 秒 | 四项交还标志全部 true |
| 最终 daemon stop | 0.395 秒 | 成功 |
| 最终只读授权查询 | 0.270 秒 | allowed，无业务事件 |

首次 connection `CBF0C281-CEBB-448A-91EB-D99C525E375C`；重连 `E9670BAF-E7ED-43B7-9210-904181EA464E`。
两份真实 release 回执为 `33-release.json`、`38-release-again.json`。最终成功连接后的控制命令没有出现 TIMEOUT、INDETERMINATE_RESULT 或 SESSION_BUSY。网站 TLS/加载异常没有使控制通道停止；这不证明这些网站当前可正常浏览。

本轮验证了连接、截图、导航、点击、翻页、历史返回、释放与同窗口重连。没有完成“文章正文→站内其他文章”的完整多文章验收；没有在生产会话人为制造只读超时或提交阶段忙碌，恢复边界仍以定向测试为证。

## 定向测试与宿主

本轮额外运行：Manager 地址 native fixture 9 项、`RegisteredManagerRecoveryTests` 3 项、插件 recovery 受影响测试 7 项，全部通过；见 `manager-address-fixture.log`、`manager-recovery-tests.log`、`plugin-recovery-tests.log`。前一轮请求恢复的 38 项定向证据保留在对应验证文档，没有全量重跑。

新 Manager 已重新启动 DSH。运行中的 Node PID 50907 监听 `127.0.0.1:61919`，使用原受控 rc.2 sidecar；未升级或修改 DSH runtime。插件安装路径仍链接到 loom-os 的本轮源码。宿主已重启，但未在真实 DSH 对话内触发失败 connect/release 恢复；插件测试不能代替真实宿主工具调用验收。

## 会话保留与收尾

所有 Runner 均先通过 NSRunningApplication 正常退出并保存会话，再退出 Manager。最初旧 daemon 的 stop 返回 SESSION_BUSY，在 Manager/Runner 退出后仅向核验过的旧 daemon PID 77387 发送 SIGTERM；该动作不算成功 release。

My、新媒体运营、Test 均从最终安装包恢复并保留运行；私有测试 daemon 已停止。33 个非 session 元数据文件摘要一致。新媒体运营的会话快照保持一窗口三标签。My 由初始七标签变为六标签，且一个已有标签 URL 变化；本轮没有向 My 发出页面控制或关标签操作，无法仅凭快照判定变化原因，未用备份覆盖当前会话。重启前及首次正常退出后的会话备份均保留本地，不能声称 My 会话逐字段不变。
