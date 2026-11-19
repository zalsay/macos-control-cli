# Manager 重启后的注册控制恢复验证

基线 `603af09` 加本轮工作区改动。未替换或重启正式安装，未操作现有浏览器环境、DSH 会话或发布页。

- 33 项定向 Swift 测试通过，覆盖注册地址、控制交还、请求恢复、Manager 路由和 daemon 在显式 `connect` 时换绑；未运行全量回归。
- `scripts/test-registered-reconnect-peer.py` 用两个独立客户端进程验证同一监听端的内核 peer PID、audit token 和代码身份，拒绝地址、方向、进程出生信息不匹配；原匿名通道校验仍拒绝命名 socket。
- `scripts/test-release-owner-dispatch.py` 验证注册浏览器交还不取得进程所有权；`scripts/test-control-read-recovery.py` 的 9 项相关请求恢复用例通过。
- 最终源码的独立签名测试包在独立目录和 `SAFARIER_HOME` 启动一个临时 Runner。首个 Manager 测试进程在会话仍开启时退出，Runner 被重新归属到 launchd。第二个 Manager 测试进程使用真实注册表、签名握手和环境锁重新认证。Runner PID、实例、窗口和页面 ID 保持，控制 token 更换；截图和四项控制交还证明通过。本地页面只加载一次。临时 Runner 已结束。

隔离测试通过实际 Runner 界面和 Core 控制链执行；未从正式 App 的 AppleEvent/DSH 对话复测。正式版需要安装新代码、由新版启动 Runner 后才具备此能力；旧运行进程不会被原地升级。无法确认旧输入清理时保持拒绝接管，未完成动作不重放。
