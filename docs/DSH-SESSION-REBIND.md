# DSH MCC 客户端会话自动更新

DSH 的自定义 `dsh-mcc-browser` 插件不在本仓库中。配套补丁位于 [examples/dsh-mcc-client-session-rebind.patch](examples/dsh-mcc-client-session-rebind.patch)，基于实际插件的 `lib/mcc-client.js` 生成；部署前须核对文件版本并保留备份。

回归测试保存在 [examples/dsh-mcc-client-session-rebind.test.mjs](examples/dsh-mcc-client-session-rebind.test.mjs)。在隔离测试目录中准备应用补丁后的 `mcc-client.js` 和 `ws` 依赖，将测试文件放在旁边，运行 `node --test dsh-mcc-client-session-rebind.test.mjs`。测试使用 fake WebSocket，不读取真实凭据，不操作桌面。

## 行为

- TLS 和 token 认证、协议格式及 scope 检查保持不变；缓存的旧 session/bootId 不再触发人工重新配对。
- 接受 Host 签发的新 session，并从序号 1 开始；有效 session 保持序号递增。
- 兼容旧版 Host：仅在 session 握手阶段、尚未发送 RPC 时，允许对缓存会话导致的 1006 关闭进行一次空会话握手。请求发送后断线不重发。
- 会话更新后，旧 connectionId/frameId 不继续使用；控制命令报告 `SESSION_REBOUND`，需要新请求重新 attach/connect。
- Host 的暂停、控制权和恢复锁仍生效；本补丁不调用 HMR，不清除恢复记录。

## 部署与验证边界

修改磁盘文件不会替换 DSH 已加载的客户端。须通过安全的插件加载入口，或经用户授权重启 DSH，才能让正式 `browser` 工具使用新代码。不要在 HMR 事务内再次发起插件重载。

验证包含 fake WebSocket 回归测试，以及从真实 DSH 容器临时加载修改版客户端、以失效 session/旧 bootId 调用 `status` 和 `windows` 的兼容性检查（旧版 Host 0.3.6）。正式插件与新版 Host 4.0.0 部署后，也通过插件入口完成了 `status` 和 `windows` 检查。状态查询和窗口枚举成功不代表 Chrome attach、截图或控制已验收；目标环境仍需分别验证这些操作与系统权限。
