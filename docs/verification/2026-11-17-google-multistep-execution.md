# 2026-11-17 新包 Test 多步骤实测

## 结论

新包已构建、校验并安装到 `/Users/yingzhang/Applications/Safarier AI.app`。在 `Test专用环境` 中，复用已有 Google「小红书笔记指南」结果页，完成了点击结果、读取正文、文档内浏览、进入站内另一篇文章、真实历史后退、再进入下一篇文章。

**页面操作链通过；控制释放未通过，因此整体验收仍未通过。** `release` 返回 `TIMEOUT`，其后 `state` 返回 `SESSION_EXPIRED`，`disconnect` 返回 `CLEANUP_UNCONFIRMED`。测试 daemon 最终停止；Test 和 My 的浏览器进程仍在，不能据此推断四项控制交还证明均已成立。

## 构建与安装

- 分支：`mcc-safarier`，使用当前未提交源码构建，没有提交或推送。
- Terra 负责打包；主 agent 独立复核源码摘要、12 项文件 pin、签名和安装结果。
- 构建目录：`.build/google-multistep-execution-20261117/`。
- 构建尝试：`packaging/attempt-20261117-090700-1142dd60eb48459392c5d14e9a444ded`。
- 构建前后与当前源码共 150 项摘要一致。
- Manager CDHash：`7ba25857720b4f5e0fd4f2c7140df4d9e802882c`。
- Runner CDHash：`eb5aab3e89a6b8047b299298395c1cdf298fae7a`。
- 使用 testing/release 候选构建，启用 `SAFARIER_BOUND_LOCAL_CANDIDATE` 和 `SAFARIER_INTERNAL_TEST_APP`；不是一次正式发行。
- 本轮未升级 DSH runtime，未运行全量回归测试。
- 校验记录：`main/package-verified.json`、`main/install.json`。

## 实测对象与证据

- Profile：`8D0DB3A8-F413-4C32-8685-FC769FC7669F`（Test专用环境）。
- Runner PID：`33779`；Manager PID：`33239`。
- Connection：`F1D96ACD-4625-4255-BF62-D03488F37C29`。
- Page：`6835C20D-6CEC-4AFB-B9A0-50B7C67E7E90`，已读取的 state 始终是同一页面。
- 授权查询返回 `allowed`；连接耗时 7.966 秒。
- 从 connect 发起至 release 发起约 774 秒，中途没有重新连接。
- 所有命令原始回执、耗时、截图均保存在 `.build/google-multistep-execution-20261117/main/`；`steps.ndjson` 汇总 CLI 步骤，原生后退有独立 JSON 记录。
- 此次沿用恢复的 Google 结果页，没有重新提交相同搜索，也没有调用 `control navigate`。因此不把本次结果算作新一轮 navigate 命令验收。

## 页面操作

| 步骤 | 结果 | 证据文件（相对 main） |
| --- | --- | --- |
| 观察 Google 结果 | 成功，关键词「小红书笔记指南」可见 | `06-observe.json` / `.png` |
| 点击 135 编辑器结果 | `sent:true,effectVerified:false`；URL 已变为 `https://www.135editor.com/essences/10033.html` | `07-click-result.json`、`09-state-article.json` |
| 读取第一篇文章 | 未通过：多次观察均白屏，state 持续 `loading:true`；AX 有文章标题但无正文节点 | `08`、`10`、`12`、`14` 的 observe JSON/PNG，`15-state-article.json`、`article-ax.txt` |
| 原生后退到 Google | 工具栏 AXPress 成功，随后截图确认回到结果页 | `16-native-toolbar-back.json`、`17-observe-google-back.png` |
| 点击飞书结果 | 成功，读取《先进工具种草丨小红书图文笔记生产手册》正文 | `18-click-lark.json`、`19-observe-lark.png`、`20-state-lark.json` |
| 点击正文目录「内容风格」浏览 | 成功，截图显示对应章节、模板及封面示例 | `21-browse-section.json`、`22-observe-section.png` |
| 点击站内「微复盘」文章 | 成功，标题、正文与 URL 均变化 | `23-open-internal-link.json`、`24-observe-internal.png`、`25-state-internal.json` |
| 真实历史后退 | 成功，回到原笔记手册；state URL 与 `20-state-lark` 一致 | `26-native-back-internal.json`、`27-observe-internal-back.png`、`28-state-back.json` |
| 点击下一篇求职指南 | 成功，正文与 URL 已更新 | `29-click-next.json`、`30-observe-next.png`、`31-state-next.json` |

5 次 sfa click 均返回执行事实 `sent:true,effectVerified:false`；页面结果由后续 observe/state 验证。页面链中没有出现 `INDETERMINATE_RESULT`、`SESSION_BUSY` 或导航后 observe 断连。

当前 sfa 没有历史后退命令，因此两次后退通过 Test 原生工具栏的 AXPress 实现，不是 sfa 命令，也没有用 navigate 假代后退。第一次尝试菜单后退时未找到可用菜单项（`13-native-back.json`），未发出后退动作；随后使用实际可用的工具栏按钮。

135 编辑器的白屏原因未定位。控制通道当时持续可用，飞书页面随后可正常读取；不能仅凭这些现象断言白屏一定来自网络或站点。

## 释放失败定位

主请求：`026B7A63-30D1-4A21-8006-B4B312F34599`。

第二阶段子请求：`765D6C25-BBA2-44A3-99A1-64C3ACD70984`。

| 日志阶段 | 单调时钟 ms | 剩余预算 |
| --- | ---: | ---: |
| Manager prepare.before | 3836798 | 9999 ms |
| Manager prepare.after | 3844715 | 2082 ms |
| Manager commit.before | 3844715 | 2082 ms |
| Runner commit permission.initial.before | 3846685 | 接近耗尽 |
| Manager coordinator.finish | 3846927 | 0，TIMEOUT |

准备阶段约耗时 7.917 秒，成功返回 `controlReleasePrepared` 后进入 commit；commit 在初始化权限检查附近就耗尽总预算。Runner 子请求最终记录 `INDETERMINATE_RESULT`，CLI 主回执是 `TIMEOUT`（10.720 秒）。这不是页面点击回执失败。

源码对应：`AutomationManager.release` 使用 `min(start + AutomationLimits.actionSeconds, entry.leaseDeadline)` 作为两阶段共用 deadline；`AutomationLimits.actionSeconds` 为 10 秒。下一步应针对释放的两阶段预算、重复校验耗时与超时后的清理确认链定位修复，不能把失败改写成成功回执。

原始日志：`release-trace.log`、`release-and-cleanup-trace.log`；原始回执：`32-release.json`。

## 收尾状态

1. `33-state-after-release`：`SESSION_EXPIRED`。
2. `34-daemon-stop`：`SESSION_BUSY`，此时 daemon 仍保留连接记录。
3. `35-disconnect`：`CLEANUP_UNCONFIRMED`，`cleaned:false,terminatedOwnedRunner:false`；本地连接记录已移除。
4. `36-daemon-stop-after-disconnect`：成功，仅证明本次私有 daemon 已停止，不替代 release 的四项证明。
5. Test Runner 与 My Runner 均仍运行，没有关闭这些浏览器。没有取得完整的 `inputReleased/artifactsCleaned/browserRetained/manualInteractionEnabled` 成功回执。

安装前正常保存 My 的 1 个窗口、6 个标签，并在安装后通过 Manager UI 恢复；立即恢复核验中 URL 和选择状态一致（`restoration-check.json`）。结束时 My 仍为 1 个窗口、6 个标签，但相对保存基线已有选中标签、1 个 URL、2 个标题变化；没有回写覆盖这些运行期间的变化，不能宣称结束时会话逐字段不变。5 项非 session 元数据摘要仍一致（`final-preservation.json`）。

预安装快照含本机私有配置，仅留在本地构建证据目录，不纳入文档或提交。
