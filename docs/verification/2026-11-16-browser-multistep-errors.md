# Safarier 多步骤浏览器实测与错误记录

时间：2026-11-16 06:32:57–06:45:16（America/New_York，UTC−05:00）。
对象：正在安装运行的 `/Users/yingzhang/Applications/Safarier AI.app`，版本 1.0.1（build 1），环境「新媒体运营」。CLI 为 `control`，使用既有 `/Users/yingzhang/.safarier-control` daemon。屏幕尺寸 1600×1134。

本轮实测 **6 组多步骤流程**，共 **46 条 control 命令、11 张截图**；2 组完整通过、2 组部分通过、2 组失败。失败次数包含后续观察、重连和清理的错误响应，不能当成独立故障数量。

## 操作与结果

| 组 | 实际步骤 | 结果 | 证据标签 |
| --- | --- | --- | --- |
| 1 | 连接 → 读取首页状态 → 截图/OCR → 点击侧栏「创作学院」→ 再截图 | 通过；官方课程、创作指导均可见 | 04–08 |
| 2 | 在学院截图定位「通用标准排排坐，优质内容有秘诀」卡片 → 单击并等待导航 → observe → state → 重新 connect | 失败；`INDETERMINATE_RESULT → SESSION_EXPIRED → BACKEND_UNAVAILABLE`，没有取得正文 | 09–12 |
| 3 | 正常重启故障浏览器并连接 → 首页截图 → 进入学院 → 截图 → 切「账号运营」→ 截图 → 切「变现指南」→ observe/release → 重连后截图 | 部分通过；账号运营切换和内容变更已验证；变现指南点击回包不确定、旧会话过期，但重连后截图确认目标分类已选中、商业合作卡片已呈现 | 13–21 |
| 4 | 学院截图 → 官方课程第 1 页点第 2 页 → 截图 → 点回第 1 页 → 截图 → release | 通过；第 2 页显示美食/时尚课程，返回后恢复原课程列表；四项释放确认均 true | 21–26 |
| 5 | 释放后重新连接 → 显式 navigate 到已观察过的首页地址 → observe → state → 再 observe → 点击学院 → observe/release | 部分通过；导航提交成功，首次观察为空白，随后 state 为 ready/loading=false、截图显示完整首页；后续返回学院时会话已过期 | 27–34 |
| 6 | 新连接 → 首页截图 → 点击「创作学院」→ 释放尝试 → 重连 | 失败；再次发生不确定结果、过期、后端不可用；此处日志前因是包资源清单校验 `BB_CHANGED`，与组 2 分开记录 | 35–42（未执行的 38–40 不计入命令数） |

每次点击都依据当次截图/OCR，使用其对应 frame。组 2 使用原生单击的 `--wait-navigation`；组 1、3、4、6 使用普通原生单击。没有向模型发送页面截图，也未用 DOM 注入操作。

## 已定位的错误证据

### A. 课程卡片导航拒绝后，根控制通道关闭

组 2 的点击发生于 06:35:39.510，耗时 2.963 秒，requestID `07B79145-D173-424C-8397-2A37DAE377CB`。从 connect 开始约 56.7 秒、成功返回后约 47.8 秒，早于 CLI 帮助所述原始绑定 90 秒上限。

随后 observe（06:35:50.391）和 state（06:35:51.097）均报 `SESSION_EXPIRED`，connect（06:36:04.229）报 `BACKEND_UNAVAILABLE`。

Runner PID 80041 的同段日志：

```text
REGISTERED_NATIVE_DIAG phase=actionAdmission monotonic_ms=40356120 contextLive=true targetPresent=false urlPresent=true download=false
NAV_DIAG phase=policyCancel reason=actionAdmission mainFrame=false initialPending=false redirectPending=false
CHANNEL_CLOSE_DIAG role=generationRunner origin=explicitClose ... function=beginClosing() pid=80041
REGISTERED_NATIVE_DIAG phase=catch ... result=CANCELLED
CHANNEL_CLOSE_DIAG role=rootRunner origin=readerLeaseDeinit ... pid=80041
ROOT_DIAG side=runner stage=generation error=automation_BACKEND_UNAVAILABLE pid=80041
REGISTERED_DIAG phase=root_closed result=unconfirmed
```

现有导航代理 `OwnedBrowserAutomationPage.swift` 的 `decidePolicyFor` 入场检查要求 `action.targetFrame` 非空，失败时取消导航、调用 `context.beginClosing()` 和 `blocked()`。此处实测 targetFrame 缺失，而 contextLive 为 true。无目标 frame 常见于新窗口请求，但本轮没有取得具体新窗口目标 URL，因此只确认触发条件与关闭路径，不断言课程实际打开成功，也不把 `mainFrame=false` 单独当作子 frame 导航的证明。

### B. 绑定生命周期内的动作结果不确定

组 3 的「变现指南」点击于 06:38:06.677 报 `INDETERMINATE_RESULT`，后续观察/释放过期；06:38:21.878 重连成功，同一 Runner PID 80917 继续可用。组 4 起始截图确认「变现指南」已选中、卡片内容已改变，所以不能把失败回包当作未执行并盲目重试。

组 5 的连接开始于 06:40:11.908，成功耗时 9.161 秒；06:41:38.196 点击学院直接报 `SESSION_EXPIRED`。这两组均靠近帮助所述 90 秒原始绑定边界，且重连可恢复。由于本轮未记录内部绝对 deadline，不宣称过期精确发生于 connect 请求后第 90 秒。

### C. 包资源重新校验发现清单变化

组 6 于 06:42:43.457 开始 connect（15.319 秒），06:42:58.829 observe（5.079 秒），06:43:03.990 点击学院（2.179 秒）报 `INDETERMINATE_RESULT`。这次同样远早于 90 秒边界。Runner PID 80917 的关闭前记录：

```text
BUNDLE_CHECK_DIAG stage=inventoryAfter elapsed_us=29569 remaining_us=2878631 result=4
BINDER_CHECK_DIAG checkpoint=first stage=resources elapsed_us=120401 result=error
CHANNEL_CLOSE_DIAG role=generationRunner origin=explicitClose ... function=beginClosing() pid=80917
ROOT_DIAG side=runner stage=generation error=automation_BACKEND_UNAVAILABLE pid=80917
REGISTERED_DIAG phase=root_closed result=unconfirmed
```

`BundleInventory.h` 将结果 4 定义为 `BB_CHANGED`。这里只确认清单一致性检查失败；没有定位具体变化文件、写入方或变化原因，不能与组 2 的导航策略拒绝合并归因。测试期间工作区的未提交文件列表也有外部变化；工作区变化本身不能证明已安装 App 的变化原因。

### D. 浏览器在前台时连接被拒绝

两次重启后的首次连接报 `BACKEND_UNAVAILABLE`。Runner 记录 `REGISTERED_ADMISSION_DIAG reason=appActive`，内部结果 `INTERACTION_REQUIRED`。切换前台到 Codex 后重连成功。内部原因与 CLI 外部错误码不一致已留档；本轮没有修改错误映射。

### E. 预检与启动客户端

技能示例的 `/Applications/Safarier.app/Contents/MacOS/Safarier` 在此机器不存在，调用 help/spaces 均以 shell exit 127 失败；通过正在运行的进程找到真实安装路径，未把这些预检当作网页操作。

一次 `launch PROFILE` 客户端在浏览器已启动后长期未退出；保留了 stdout/stderr。测试结束只终止本轮创建且命令行完全匹配的 launch 客户端 PID 80003，没有用该清理动作终止 Manager 或其他浏览器。

## 错误响应统计

| CLI 错误码 | 次数 |
| --- | ---: |
| SESSION_EXPIRED | 8 |
| BACKEND_UNAVAILABLE | 5 |
| INDETERMINATE_RESULT | 3 |

合计 16 个错误响应，30 个成功响应。逐条文件保存真实退出码、完整 stdout/stderr、请求 ID、UTC 与纽约时间、命令参数和耗时。

## 交付证据

证据根目录：`/Volumes/RC500/dev/safarier/.build/browser-multistep-20261116-01/`（本轮创建，目录权限 0700）。

- `commands.ndjson`：46 条命令的完整原始响应和时间。
- `errors.ndjson`：其中 16 个错误响应。
- `runner-live.log`：从本轮预检后记录的 byte offset 起提取的 Runner 增量日志；`initial-runner-tail.log` 是本轮开始时已有的末尾日志，明确区分历史证据。
- 各标签 `.json` 和 11 张 `.png`：单步响应、OCR 与复制保留的页面截图；释放后仍可查看。
- `environment.json`、`session-before.json`、`session-after.json`、`git-status-final.txt`：环境与恢复状态。
- `run.py`、`step.py`、`final-pass.py`：本轮取证辅助脚本。`final-pass.py` 在组 6 首次点击失败即抛异常，并执行 finally 清理；后面的分类切换没有执行。

截图/OCR含当前账号页面资料，仅作本地取证；未读取 Cookie、密码或订阅链接。

## 清理与边界

只正常重启了本轮目标环境的浏览器进程。最终后台重连成功，06:45:05 的 state 确认小红书首页 `/new/home`、ready、loading=false；06:45:08 的 release 成功（7.553 秒），`inputReleased`、`artifactsCleaned`、`browserRetained`、`manualInteractionEnabled` 全部 true。前后会话均为 1 个窗口、2 个标签页。

没有修改产品代码、没有构建、没有运行全量回归；工作区原有与其他任务新增的改动均未回滚。没有发帖、点赞、收藏或提交账号设置。本轮没有读到课程正文、没有制作 Skill，也没有把课程封面当作教程已学习内容。
