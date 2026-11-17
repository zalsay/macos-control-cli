# DSH 插件历史连接阻塞与遗留 socket 恢复

日期：2026-11-17。本轮没有重建 App、重启浏览器、导航、输入、提交或推送。主 agent 调查和复核；只运行受影响的插件定向测试。

## 实证根因

DSH 原聊天 `session-c054d862-d326-4794-8d17-f4fd93aff31d` 从成功 connect 的历史恢复：

- runtime：`/Users/yingzhang/sfc-Egkhvl`
- connection：`FCFF6FAF-875C-4914-AB85-A2039E8A3341`
- profile：`9080635F-0A64-4ECC-9969-58C9618B5072`（新媒体运营）

本轮日志显示，新 connect 先被插件拒绝 `Release the current connection before connecting again`；随后的 state 转发至旧 runtime，返回 `control: unavailable or invalid request`。本机没有控制 daemon，浏览器 Runner PID 50762 仍在运行。

旧目录内仅剩 `control.sock`，为当前用户所有、0600 的 Unix socket。实际 connect 返回 ECONNREFUSED（61），前后 inode 一致。这是此前 App 替换时终止旧 daemon 后的遗留文件。CLI 的通用错误在连接 socket 阶段产生，不能解释成页面操作未执行或浏览器退出。

两个问题组合造成恢复死结：历史连接一直被当成现存连接，插件拒绝显式 connect；daemon start 又因已有 socket 直接查询旧 endpoint，不会启动新 daemon。

## 源码修复与操作恢复

修复位于独立插件源码 `/Volumes/RC500/dev/loom-os/plugins/sfa-tool/`，安装目录仍链接至这里。没有在 Safarier 叠加另一套通道。

1. 从成功 connect 的历史及内存记录 profileID。
2. 同 profile 的显式 connect 允许送到真实 CLI：daemon start 和 connect 各一次；由后端判断现有连接是否忙碌。
3. start/connect 失败保留旧路由；成功后才更新 connection。重载后的历史恢复也遵循这一点。
4. 跨 profile 仍要求先释放现有连接，避免遗弃另一环境的所有权；已成功 release 但 daemon 清理未完成时仍沿原清理路径。
5. 不自动重连、不重放导航或输入，也不把 generic stderr 当作释放证明。

本次确认旧 socket 无监听且 inode/所有者/类型未变化后，仅将其改名备份：
`/Users/yingzhang/sfc-Egkhvl/control.sock.stale-20261117-173929`。
未在插件增加自动删除 socket 的机制；未来异常退出遗留 socket 的自动恢复不属于本次源码修复。

## 定向验证

新增四项测试，其中三项在修复前因旧 connect 拦截失败；修复后，连同五项受影响历史恢复/清理测试共九项通过。覆盖同 profile 大小写兼容、成功更新 connection、失败保留旧路由、daemon start 失败不发送 connect、跨 profile 不遗弃所有权。`node --check` 通过。

证据在 `.build/stale-routing-20261117/`，包括 `red.log`、`green.log`、`socket-recovery.json`。

主 agent 用真实插件 apply/execute、原聊天工具历史和真实子进程适配，调用当前已安装 sfa；不是模拟 CLI，也没有把结果写入用户聊天历史：

| 操作 | 耗时 | 结果 |
| --- | ---: | --- |
| 同 profile 显式重连 | 3.694 秒 | 成功，connection `6565F46C-8F94-4398-8170-922B235FC1AD` |
| state | 0.641 秒 | ready，loading:false，正确 profile |
| release 及 daemon stop | 1.234 秒 | 四项真实交还标志全部 true，stop 退出码0 |

connect request `7F5A6ED9-27BF-4004-89CE-93A7E7281F63`；state request `ACFF8A4C-08BF-4CA0-9939-32F26E7FB790`；release request `1FE49A36-C81A-4ED6-991F-E364FEAAEB67`。原始回执为 `live-connect.json`、`live-state.json`、`live-release.json`。

这证明新插件代码可以从该历史恢复路由并通过真实 CLI 重连、读取和交还；它不是 DSH 宿主内的一次工具执行。

## DSH 加载与收尾

核对近期聊天均已 turn/end 后，使用 Safarier 活动栏原有上下文菜单“重启服务”，正常重启 DSH。新 Node PID 59631，rc.2，监听 `127.0.0.1:61919`，插件安装链接仍指向上述源码。Manager PID 50706 和新媒体运营 Runner PID 50762、启动时间均未变化。

本轮未在 DSH 对话内发起新的工具调用，因此实际宿主内重连仍待验收。原聊天没有被改写：旧 connection 不会复活，下一步应显式调用同 profile 的 connect，再使用 state/observe。测试完成后 daemon 已正常停止，当前没有占用浏览器控制；浏览器保留运行。
