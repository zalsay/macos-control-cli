# 移除重复检查后的打包与 Test 实测

日期：2026-11-17。结论：本轮 Test 多步骤页面操作、Backspace 后退、释放与再次接管全部通过。两次 release 分别为 0.760 秒、0.809 秒，均取得四项真实交还回执。未运行全量回归。

## 包与运行环境

- 当前分支 `mcc-safarier` 的工作区源码，包含此前 release 分阶段预算和 back 命令修复；没有提交或推送。
- testing / release 构建，启用 `SAFARIER_BOUND_LOCAL_CANDIDATE`、`SAFARIER_INTERNAL_TEST_APP`。
- 产物：`.build/registered-checks-package-20261117/packaging/attempt-20261117-101330-d32fdb2b7947457a98a2681a712dfd82/Safarier AI.app`。
- 150 项源码摘要在构建前后与核验时一致，12 项文件 pin 及 Manager/Browser 签名核验通过。
- 已安装到 `/Users/yingzhang/Applications/Safarier AI.app`，使用原有事务安装器保留旧包备份；DSH runtime 未变更。
- 正常退出旧 My 和 Manager 后安装；通过 Manager 恢复 My，再启动 Test。
- 新 Manager PID `69999`；My PID `70069`；Test PID `70080`。
- Test profile：`8D0DB3A8-F413-4C32-8685-FC769FC7669F`。
- 授权只读查询：`allowed`。

## 页面与执行回执

原始证据目录为 `.build/registered-checks-package-20261117/main/`，下列文件名均相对此目录。

| 操作 | CLI 耗时 | 结果与证据 |
| --- | ---: | --- |
| 连接 Test | 2.778 秒 | `04-connect.json` |
| 导航 Google 搜索“小红书笔记指南” | 0.594 秒 | `06-navigate-google.json` 返回 `navigationSubmitted:true,effectVerified:false`；`07-observe-google.png` 确认真实结果页 |
| 点击飞书搜索结果 | 0.594 秒 | `08-click-result.json`；`09-observe-article.png` 确认“小红书图文笔记生产手册”正文 |
| 浏览“内容风格”章节 | 0.616 秒 | `10-browse-section.json`；`11-observe-section.png` 确认模板、封面内容 |
| 进入站内“微复盘”文章 | 0.625 秒 | `12-click-internal.json`；`13-observe-internal.png` 确认新文章正文 |
| sfa control back | 0.602 秒 | `14-back.json`；`15-observe-back.png` 确认回到笔记手册；此次使用 sfa 的 Backspace 命令，不是工具栏替代 |
| 进入下一篇求职指南 | 0.623 秒 | `16-click-next.json`；`17-observe-next.png` 确认新正文；`18-state.json` 为 ready、loading:false |
| 释放控制 | 0.760 秒 | `19-release.json`，四项交还标志全 true |
| 停止 daemon | 0.416 秒 | `20-daemon-stop.json`，成功 |
| 重启私有 daemon 并重连同一 Test | 3.784 秒（connect） | `21`、`22` 回执成功；`23-reconnected-state.json` 的 profile/runner/window/page 与 URL 全部和释放前一致 |
| 再次释放 | 0.809 秒 | `24-release-again.json`，四项交还标志全 true |
| 最终停止 daemon | 0.382 秒 | `25-daemon-stop-final.json`，成功 |

7 次 observe 均成功，耗时 1.281–1.813 秒。页面效果由主 agent 查看保存的实际截图确认；原生投递回执不作为页面效果证明。没有重复投递任何失败动作。本轮 25 个记录步骤退出码全部为 0，没有出现 TIMEOUT、INDETERMINATE_RESULT 或 SESSION_BUSY。

第一条 connection：`F8F38854-6263-4E5B-A027-358B9B520426`。
重连 connection：`2FBF3A44-0468-458B-AFB6-1CDA7E372711`。

## release 阶段耗时

首条 release request：`F0B82BB8-7FA5-456B-8B78-E0A1AAFF374A`。
commit 子请求：`9C3784CE-6A66-4E18-B60E-86B725F1AB9A`。

| Manager 阶段 | 单调时钟差值 |
| --- | ---: |
| prepare | 6 ms |
| commit | 4 ms |
| takeOwner / 通道交还 | 187 ms |

对应 `release-trace.log`、`release-full-trace.log`、`release-phase-times.json`。相较前次 prepare 7.917 秒，本次为约 0.006 秒；CLI release 由前次 10.720 秒后超时变为本次 0.760 秒成功。两次是不同运行样本，不作跨环境性能保证。

两次回执的 `inputReleased`、`artifactsCleaned`、`browserRetained`、`manualInteractionEnabled` 均为 true；同一窗口可再次接管和释放。这些是系统回执和重连事实，没有把它描述为用户亲手操作验收。

## 会话与收尾

- 私有测试 daemon 已停止；新 Manager、Test、My 浏览器保留运行。
- My 正常退出保存和恢复的会话为 1 窗口 7 标签。立即恢复检查中 URL 和选择状态一致，仅末尾标签标题变化。最终检查中第一个标签 URL/标题发生变化，未覆盖运行期间的变化；不宣称整个会话逐字段不变。
- profiles、subscriptions、bookmarks、credentials 共 5 个非 session 元数据文件摘要不变，见 `final-preservation.json`。
- 安装记录、会话快照和原始截图留在本地 `.build`，不纳入提交。文档只记录验证结果。
