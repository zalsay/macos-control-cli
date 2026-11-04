# 滚动方向、回执与真实 Chrome 诊断

## 既有契约（没有翻转底层方向）

`scroll --connection <id> --frame <frame> --x <x> --y <y> --delta-y <n>`：

- `delta-y` 为 `[-1200,1200]` 内的非零整数；**正数向下、负数向上**。Native 的 CGEvent 轴取负是内部转换，调用方不再反转。
- x/y 来自当前完整窗口截图，在要滚动的内容区域。坐标滚轮与当前键盘焦点的 PageDown 不等价，不能自动切换兜底。
- `ok:true, sent:true` 只说明事件投递，不证明可滚动内容移动。顶部继续向上、底部继续向下可以合法无变化。用 observe 确认；错误必须记录原始 `error.code/message`，不能只写“回执异常”。

## 2026-10-28 本地真实 Chrome 复验

用户明确要求远端正在使用后，停止全部远端访问。本节只测试本机：未连接公网 Host、未执行 SSH、未修改远端服务或配置。

使用独立解压的 0.3.6 候选二进制和相邻真实 helper，分别走两条链路，各完整通过两轮（共 20 次实际滚轮事件）：

1. 本机 CLI → 私有 daemon → Native → 隔离 Chrome profile。
2. 本机 CLI → `wss://127.0.0.1:<临时端口>/mcc/v1` → 本机私有 Host/daemon → Native → 另一个隔离 Chrome profile。真实 TLS/独立 token，不使用 fake Native。

滚动坐标来自 mcc 同帧 OCR 的 `SCROLL TARGET`。测试页只记录浏览器事件与位移；不使用 DOM/CDP 执行滚动，不访问账号业务页，不调用 Jev。

两条链路、两轮结果一致：

| 顺序 | deltaY | 容器 scrollTop | 回执及页面事件 |
|---|---:|---:|---|
| 初始 | — | 0 | — |
| 1 | -1200 | 0 | sent:true / trusted wheel -1200 |
| 2 | -1200 | 0 | sent:true / trusted wheel -1200 |
| 3 | +1200 | 1200 | sent:true / trusted wheel +1200 |
| 4 | +1200 | 2400 | sent:true / trusted wheel +1200 |
| 5 | -1200 | 1200 | sent:true / trusted wheel -1200 |

额外断言：

- `0`、`+1201`、`-1201` 均返回 `INVALID_ARGUMENT / deltaY 必须为 [-1200,1200] 内的非零整数`，无新增页面事件。这是主动构造的错误，不是用户原始的异常回执。
- 先用 mcc 点击聚焦自有容器，再按 PageDown，位移从 1200 到 1520，收到 trusted PageDown；此结果不意味着 PageDown 可以替代任意坐标滚轮。
- 页面本身的 `scrollY` 始终为 0，确认滚动的是目标内层容器。最终 observe/OCR 与截图都显示 `paneTop: 1520`。
- 测试连接已断开；自有 Host、daemon、Chrome 和 HTTP fixture 全部退出；生成的 token、私钥及独立 profile 已清除。本机默认 daemon 测试前后都是 `running:false`；实际安装仍为 0.3.5+1，未安装或部署候选版。

本地证据：ignored `target/scroll-local/report.json`、`report-first-pass.json`、两条链路的原始回执/事件记录及 `final-observe.jpg`。补存截图的中间一次驱动因 macOS `/tmp` → `/private/tmp` 规范路径比较失败，在首次输入前中止；清理完成后修正测试驱动再完整通过，不属于 mcc 输入失败。

结论仍限定为：**未复现底层滚轮投递故障**；用户贴出的操作使用 `-1200`；若意图向下，应改用 `+1200`，但不能从该片段推断当时的滚动方向意图。缺少原始命令及错误 JSON，不能认定用户业务页的问题已修复，也不翻转原滚动方向、放宽范围或新增自动键盘兜底。

## 2026-10-28 真实远端验证

在远端 Mac 使用已安装的 0.3.5 mcc/helper、独立 GUI LaunchAgent/私有 loopback WSS Host、独立 token/runtime/state，并经 SSH 隧道连接；没有占用常驻 Host 的控制连接。只打开自有测试页的新 Chrome 窗口，不进入业务页，不使用 DOM/CDP 控制。坐标由同帧 OCR 获取，测试页只记录实际浏览器事件与 scrollTop 供验收。

| 动作 | 容器 scrollTop | 回执/实际事件 |
|---|---:|---|
| 初始 | 0 | — |
| -1200 | 0 | sent:true，收到 trusted wheel -1200 |
| 再 -1200 | 0 | sent:true，收到 trusted wheel -1200 |
| +1200 | 1200 | sent:true，收到 trusted wheel +1200 |
| 再 +1200 | 2400 | sent:true，收到 trusted wheel +1200 |
| -1200 | 1200 | sent:true，收到 trusted wheel -1200 |
| 点击聚焦测试容器后 PageDown | 1580 | sent:true，键盘焦点属于该容器 |

越界测试 `+1201` 返回 `INVALID_ARGUMENT`，消息为 `deltaY 必须为 [-1200,1200] 内的非零整数`；未增加浏览器事件。这是主动构造的范围错误，**不是用户未提供的那一次原始异常回执**。

本轮额外确认一个独立的实际配置问题：本机 PATH 的 mcc 为 `0.3.5+1`，常驻远端 Host 为 `0.3.5`。本机该版本对常驻 Host 的只读 status 返回 `PROTOCOL_ERROR / 远程版本、scope 或能力无效`；保留的匹配 0.3.5 客户端可以正常连接。若业务 Agent 使用的是前者，scroll 和 PageDown 都在握手阶段失败，并未进入输入层。不能在缺少原始命令/JSON 时断言用户当时一定使用了哪个客户端。

候选版仅细化原 parse_hello 版本错误文案，显示经白名单限制的两端版本并说明未发送桌面操作；错误代码和严格匹配仍不变，不自动降级或回退本机，也不回显任意远端文本/超长字段。

本轮没有复现底层滚轮投递失败，确认向下应使用 `+1200`、向上使用 `-1200`，不能据此推断用户当时的方向意图。业务页特定的滚动容器、帧/焦点/暂停或网络错误仍需原始命令和 JSON 判断，不能据此宣称用户所有滚动问题均已修复。

测试窗口已关闭、连接断开、私有 Host/daemon/服务与隧道停止、临时 token 删除；清理时的只读快照显示常驻 Host 为 ready、无控制连接、journal clean；之后复查出现 NOT_OWNER，旧入口更新安全中止，没有修改入口指针、抢占控制、清锁或重启常驻 Host。以上均为当时状态，不代表当前远端空闲；用户要求本地测试后不再访问远端。证据位于本地 ignored `target/scroll-diagnostics/`。早期测试 Host 启动未就绪曾返回连接失败，已清理并为测试驱动增加监听就绪检查；这不是滚动回执错误。
