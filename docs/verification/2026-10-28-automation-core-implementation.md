# 2026-10-28 首批后台自动化核心功能代码

## 范围与状态

- 工作目录：`/Volumes/RC500/dev/safarier`；分支 `mcc-safarier`；HEAD 仍为 `2f32d21248deaffd8c8c1152a39912aa46350c7e`，未提交。
- 用户明确要求继续功能代码，按已批准设计先实施不接入桌面的 Core 层；不是继续仅做工具链调查。
- 实现由两个 terra-worker 执行；主代理已核实二者实际模型均为 `gpt-6.1-terra` / `high`。代码 review、独立反例和最终组合验收只由主代理执行，未分派 reviewer。
- 本批次源代码已落地，独立检查与正式产品编译通过；原 XCTest/GUI/发布门禁未通过，不等于可用 App 交付。未开放外部控制入口或执行页面动作。

## 功能代码

| 文件 | 已实现内容 |
|---|---|
| `Sources/SafarierCore/AutomationProtocol.swift` | v1 强类型动作/回执/错误/结果模型、会话 token 安全随机生成及 canonical base64url 检查、严格 JSON codec、输入限额、脱敏描述 |
| `Sources/SafarierCore/AutomationReplayCache.swift` | 每个授权 caller/session 范围内的 begin 预留、in-flight 拒绝重复执行、完成回执重放、不同参数拒绝、256 容量上限、显式 30 秒 lease 续期与过期拒绝 |
| `Sources/SafarierCore/AutomationChannel.swift` | 仅 connected AF_UNIX/SOCK_STREAM 的私有 socketpair、4 字节大端 framing、65,536 字节 payload 上限、分片读写、EOF/截断处理、close/cancel 唤醒、局部 SO_NOSIGPIPE、有限发送背压 |
| `Sources/SafarierCore/Profile.swift` | 在原构造/Codable/duplicated 路径新增 `allowsBackgroundAutomation=false`；旧 JSON 默认 false；复制 Profile 不复制许可；其余原设置保留 |

协议解码拒绝未知 action/字段、结构化扫描到的重复 key（含转义同义 key）、过深 JSON、错误类型、非法 token/URL、非有限坐标/滚动、过量输入等。文本最多 16,384 UTF-8 字节，frame 最多 65,536 字节；不暴露任意 script/selector、全局鼠标或按键接口。

回执为 success/result 或 failure/error 的互斥强类型；success 必须含有效 requestID，无法解析请求 ID 的失败可明确输出 null。nativeDelivered 只是协议效果标签，本批次没有原生页面 driver 调用，不能据此声称执行过点击/打字。

通道发送预算 262,160 字节（4 个最大帧及其头），满时 typed sendBackpressure；I/O 在独立串行队列，在途操作持有 F_DUPFD_CLOEXEC 复制的 FD，close 先 shutdown 共享 socket 再释放自身 descriptor。成功 adopting 消费输入 FileHandle；调用方不可继续使用该 handle。缓存是值类型，所有者必须串行访问，并在鉴权通过后明确续期，不能将其当作线程安全授权服务。

## 测试文件与入口

- `Tests/SafarierCoreTests/AutomationProtocolCases.swift`：共享纯 Foundation 校验。
- `Tests/SafarierCoreTests/AutomationChannelCases.swift`：共享 async/POSIX 校验。
- `Tests/SafarierCoreTests/AutomationProtocolTests.swift`、`AutomationChannelTests.swift`：正规 XCTest 包装，保留在原目标；未执行。
- `Tests/SafarierCoreTests/ProfileTests.swift`：只追加旧 JSON/roundtrip/复制许可测试，旧测试未删除。
- `scripts/test-automation-protocol.sh`、`scripts/automation-core-tests/ProtocolMain.swift`：直接编译全部实际 Core，再运行共享纯校验。
- `scripts/test-automation-channel.sh`、`scripts/automation-core-tests/ChannelMain.swift`：直接编译实际 channel，运行共享校验，有 20 秒子进程硬超时。

以上独立入口不是替代 XCTest 的框架或假实现。只运行 Core/POSIX 确定性测试，不启动 GUI/App，不创建监听服务，不操作用户桌面，不读写真实 Profile 或钥匙串凭据。

## TDD 与主代理修复轮次

1. 协议初始 RED：exit 1，真实错误为 `AutomationRequest`/相关 API 不存在；通道初始 RED：exit 1，目标源文件尚不存在。各自日志保留在 `.build/automation-protocol/`、`.build/automation-channel/`。
2. 首次主代理用全部实际 Core 静态编译跑独立验收：71/71 自编协议样例、325 共享核心 checks、28 通道 checks 通过，但 success/requestID=null 负例失败，组合进程 exit 1。主代理定位后由 Terra 先补回归，再加 success ID 校验，RED exit 1 → GREEN exit 0。
3. 主代理另一个独立反例发现 Swift String 规范等价将 NFC/NFD 两种不同字节的 insertText 当作同请求，cache 返回 inFlight 而非 REQUEST_ID_REUSED。Terra 先补 RED 再改 cache 私有比较：文本 UTF-8、URL absoluteString UTF-8 必须匹配；JSON 空白/顺序/相同解码值和 UUID 大小写不造成假冲突。begin 和 complete 均使用该比较，in-flight/completed/错误完成均有回归。

原始反例与主代理首次失败未覆盖或删除：

- `.build/automation-feature-main-review/first-independent-review.*`
- `.build/automation-feature-main-review/unicode-replay-red.*`
- `.build/automation-protocol/request-id-regression/red.*`、`green.*`、`unicode-red.*`、`unicode-green.*`

## 最终验证（实际执行）

主代理将最终全部 `Sources/SafarierCore/*.swift` 编为静态模块，用相同生产代码运行共享 cases、独立样例、协议/通道往返和 Profile 兼容检查；编译前后源码哈希保持一致。

| 验证 | 结果 |
|---|---|
| 最终 Core 整体编译 | exit 0 |
| 主代理联合第 1/2/3 轮 | 每轮 exit 0；340 核心 checks + 28 通道 checks + 71/71 独立协议样例及组合检查通过 |
| 通道独立脚本另跑 3 轮 | 各 exit 0，28 checks/轮 |
| 协议独立脚本 | exit 0，340 checks |
| 主代理 Unicode 独立反例修复后 | exit 0 |
| 新 XCTest 包装及 ProfileTests 语法解析 | exit 0；仅语法，不代表 XCTest 类型检查或运行 |
| 修改后正式 Safarier 产品 Debug 编译/链接 | exit 0；包含 main.swift，未执行二进制 |

340 是共享 runner 的检查计数，其中包含容量循环断言，不是 340 个独立 XCTest 测试。原 XCTest 和完整 swift test 从未被跳过后冒充通过，本机仍缺真实 XCTest。

产品编译仍使用此前已验证的命令级诊断 overlay、独立 module/cache/scratch 输出和 `--jobs 2`，并非默认 SwiftPM 已修复，不修改原 Package.swift 或系统文件。证据位于 `.build/automation-feature-main-review/final-product-build.*`；其他最终命令、退出码和源码哈希均在同目录。GUI、App 运行、release、原打包脚本/签名验收本轮均未执行。

## 保留限制与下一步

- 还没有 AppleScript sdef/命令、Manager 鉴权/路由、实际 Process stdin 继承、Runner nonce 握手、GUI 许可开关、后台窗口启动或页面输入接入；旧 normal App 的启动/呈现路径没有改变。
- channel 初始化 socketpair 后设置初始 FD_CLOEXEC 存在理论上的并发 exec 窗口；后续 Process 集成必须验证/解决继承同步或默认关 fd 策略。不能据当前无子进程的测试声称该问题已消除。
- 未注入所有 EINTR/资源耗尽/系统调用失败分支；FD 检查与 close/cancel 只覆盖本轮列出的场景，不能宣称所有失败路径无泄漏。
- 缓存/协议 API 不是授权主体；Profile 是否允许、session token 是否属于调用方、目标身份和后台状态仍由未来 Manager/Runner 绑定验证。
- 旧 XCTest、实际 Manager 冷启动、多实例 Apple Event 接收身份、UI 逃逸、不干扰输入的真实页面矩阵仍是接入/交付门禁。本轮 Core 检查不能代替它们。
- 未提交、推送、安装、发布、修改全局工具链/TCC，也未新增全局输入/JS 兜底。
