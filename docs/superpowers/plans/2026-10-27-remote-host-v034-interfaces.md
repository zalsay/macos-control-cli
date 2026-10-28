# 0.3.4 剩余阶段接口与执行裁决

2026-10-27，用户要求继续直到开发完成，不再停在阶段性交接。绑定已确认spec与主计划；本文件是协调接口，非另起执行机制。实现继续terra-worker，全部review由主agent。

## 写集

- A（既有证书/共享入口worker）：daemon/native/Jev/Service、execution、Swift暂停/协议/main和相关原生/取消/daemon测试。不能改Cargo、remote/mod、args/main客户端前端或B/C写集。
- B（既有会话worker）：remote/host.rs、client.rs、wire.rs（按需）、原protocol/session、private_files的必要会话原子存储扩展、Cargo/lock、remote/mod.rs和remote_host/client/e2e测试。不能改A执行器/Swift或C args/options/images。
- C（新增Terra）：remote/options.rs、images.rs、args.rs、main.rs、remote_args/images测试；不能改Cargo、remote/mod.rs、execution或A/B实现。
- 主agent：接口/计划/业务说明、review、独立复测、最终集成修正协调；不把review委托。

## C产出的选项类型

```rust
// src/remote/options.rs；Debug只能输出路径/无凭据URL，不读取文件。
#[derive(Clone, Debug)]
pub struct HostOptions {
    pub listen: std::net::SocketAddr,
    pub tls_cert: std::path::PathBuf,
    pub tls_key: std::path::PathBuf,
    pub token_file: std::path::PathBuf,
    pub state_dir: Option<std::path::PathBuf>,
    pub allowed_file_roots: Vec<std::path::PathBuf>,
}
#[derive(Clone, Debug)]
pub struct ClientOptions {
    pub url: String,
    pub ca_cert: Option<std::path::PathBuf>,
    pub token_file: std::path::PathBuf,
    pub state_dir: Option<std::path::PathBuf>,
}
pub enum HostCommand {
    TlsInit { sans: Vec<String>, output_dir: std::path::PathBuf },
    TokenInit { output: std::path::PathBuf },
    Start(HostOptions),
    Recover { state_dir: Option<std::path::PathBuf> },
}
```

args::Command增加 `Host(HostCommand)` 和 `Remote { options: ClientOptions, command: Box<Command> }`。remote内只允许Request（不含jevKey），禁止嵌套/Config/Daemon/Host。main在execute_local之前处理两新变体；初始化调credentials，Host::run和client::run按下文调用。现有help/version、本地三入口语义保留。

CLI：
- host tls init --ip/--dns（可重复）--output-dir <abs>
- host token init --output <abs>
- host start [--listen ip:port，缺省127.0.0.1:8765] --tls-cert <abs> --tls-key <abs> --token-file <abs> [--state-dir <abs>] [--files-root <abs>，可重复]
- host recover [--state-dir <abs>]：仅Host本地显式恢复，不经WS。
- --remote <wss URL> [--ca-cert <abs>] --token-file <abs> [--remote-state-dir <abs>] <原Request命令>
URL /mcc/v1，缺省路径/可规范化为/mcc/v1；拒绝其他path、userinfo/query/fragment、非WSS、重复全局参数。只读help/version不需要remote读key或启动runtime。

## A产出的原daemon受控内部API

所有者字符串是Host私有随机capability，不来自网络对端字段、不进入普通Debug。公开Rust接口供同机Host调用，但绝不放进WSS动作白名单。

```rust
pub fn remote_claim(runtime: &Runtime, owner: &str) -> Result<serde_json::Value>;
pub fn remote_call(runtime: &Runtime, owner: &str, operation: &str, request: serde_json::Value) -> Result<serde_json::Value>;
pub fn remote_pause(runtime: &Runtime, owner: &str, operation: Option<&str>) -> Result<serde_json::Value>;
pub fn remote_control_state(runtime: &Runtime, owner: &str) -> Result<serde_json::Value>;
pub fn remote_release(runtime: &Runtime, owner: &str) -> Result<serde_json::Value>;
pub fn remote_recover(runtime: &Runtime, owner: &str) -> Result<serde_json::Value>;
// execution.rs；原prepare/model/disabled/window/version/dispatch路径只维护一份。
pub fn execute_remote_request(request: serde_json::Value, scope: Scope, owner: &str, operation: &str) -> Result<serde_json::Value>;
```

- claim只在daemon已有/调用方显式启动后调用，本函数不自动新建helper；原连接已被他人占用、helper暂停/旧恢复锁则拒绝，不夺取。不支持此协议/原生暂停能力时拒绝，不能把旧helper当可用。
- claim回执至少包含owned:true、daemonPid、helperPid，用于Host私有恢复记录核对。owner与活动operation由原daemon所有权注册表在Service锁外检查；同一原Service/原helper执行。
- remote_call原本地信封新增受控context，而非给用户JSON加内部字段。原生Jev的每请求cancel token独立于全局stopping，暂停在Service主锁外能发出并收到匹配ACK；迟到operation不暂停新请求。
- pause返回 `paused:true, inputEpoch, lease(可null), recovered:false` 仅在原生保持暂停ACK确认后；不确认返回CANCEL_UNCONFIRMED并持久fail-closed。无lease时也保留transport恢复锁，不能被beginExecution覆盖。不能直接用旧cancel再connect。
- state返回当前owner匹配后的原生paused/phase/inputEpoch/lease及recoveryRequired；人点击原继续后，同lease+更新epoch+原countdown/running才可让Host恢复原owner，不能凭WebSocket消息解除。
- release只在已确认显式disconnect、无活动op、没有暂停/恢复锁时释放capability。recover是Host本地显式命令：先取消并核对无活动op/原生安全，再按本地本人要求清理恢复锁及原连接；WS永远不调用它。
- 本地非owner改变桌面请求在remote owner有效时返回BUSY/NOT_OWNER；status/apps/windows/permissions只读与本地明确stop保持可用；不要改变未使用remote的本地行为。
- Host退出/重启不清零暂停。只能终止/清理可证明自己持有的资源，不能kill或重启他人helper。没有活daemon时recover不得悄悄start一个新helper；旧helperPid仍存活/无法证明停止必须保守拒绝。
- A适配execute_local对新Host/Remote变体应显式拒绝“只允许CLI前端分派”，main已先处理，不留unhandled编译分支。

## C产出的图片接口

```rust
pub fn load_frame(frames_dir: &std::path::Path, request_id: &str, frame_id: &str)
 -> Result<(super::protocol::ImageManifest, Vec<u8>)>;
pub fn save_frame(manifest: &super::protocol::ImageManifest, bytes: &[u8], output: Option<std::path::PathBuf>, cache_dir: &std::path::Path)
 -> Result<std::path::PathBuf>;
```

Host先调用SessionManager.authorize_frame，才可load。load只由可信frames_dir+合法frameId派生<frameId>.jpg，不接受用户路径；对目录/文件做当前owner/私有权限、类型、symlink、单硬链接、open前后dev/inode与长度检查，最多JPEG<1MiB，摘要SHA256，32帧生命周期仍归Service。save本地0600/create_new/no覆盖，manifest长度/摘要先校验，失败清理自己半文件；输出path是真本地路径。复用private_files写入原语，不复制配置存储。

## B产出的传输入口

```rust
pub fn host::run(options: super::options::HostOptions, scope: Scope) -> Result<serde_json::Value>;
pub fn host::recover(state_dir: Option<std::path::PathBuf>, scope: Scope) -> Result<serde_json::Value>;
pub fn client::run(options: super::options::ClientOptions, request: serde_json::Value,
 output: Option<std::path::PathBuf>, scope: Scope) -> Result<serde_json::Value>;
```

WSS内的wire约定（所有JSON有界，所有未知字段拒绝）：
1. TLS+Bearer认证及固定path/subprotocol后，Host发既有Hello，版本精确匹配，scope/boot/capabilities明确；认证前不启动daemon/helper。
2. 客户端发session请求：`{type:"session", remoteProtocol:1, scope, session:<缓存值或null>, bootId:<缓存值或null>}`。Host返回 `{type:"session", session:<sid>, bootId, state}`。新session只读，不自动夺取控制；boot变化/旧sid失效不偷偷重置为新控制者。
3. 客户端发既有RemoteEnvelope；Host把本socket绑定SessionManager.begin_rpc返回的内部ticket，不接受peer ticket。control的reserve/claim与失败rollback正确；readonly apps/windows走原共享入口，拥有控制的动作走execute_remote_request。
4. Host用线程/通道执行原backend，主WS循环保持5秒ping及最多15秒失联检测，不持Session锁等待动作。disconnect、native USER_PAUSED、Host失联状态都不能被重连绕过；所有socket退出路径回收有界ticket/close许可，不泄漏到第65次永久BUSY。
5. 回执：`{type:"result", id, sequence, response:<原response_for包裹的对象>, image:<ImageManifest或null>}`，没有Host imagePath。observe或frame才发图；click-target内部图仍留Host。随后按manifest收有界二进制块，不使用base64。客户端核对id/seq/图片身份后保存，并把本地imagePath放回response。
6. 客户端接收完整回执/图后发 `{type:"ack", id, sequence}`，Host通过内部ticket验证并回 `{type:"acked", id, sequence}`，随后正常close；不disconnect桌面连接。动作已投递但响应/ACK失联返回REMOTE_OUTCOME_UNKNOWN和requestId，不自动重发。
7. paused会话可走专门 `{type:"query", session, sequence, id, request:<原请求>}` 查询已知结果，不dispatch副作用；CLI对不确定结果不自动重放。先提供文档化WS查询，若增加CLI查询只读入口须说明语法且不变成执行重试。

状态/凭据存储只在MCC_CONFIG_DIR下的remote-host/<scope>和remote-sessions/<endpoint/CA/scope>，或显式state_dir。目录0700、文件0600、有界读、原子发布与锁复用private_files；不改models.toml。Host日志不含token/session/原请求/截图。持久journal在取得控制前写pending/owner+pid，原连接证明释放后才清clean；上次未clean启动进入recovery_required并拒绝输入，可读状态。恢复只走本地host recover且使用记录私有owner；不得通过删client缓存恢复输入。

Client跨CLI进程缓存session+boot+序号、OS文件锁不排队；没有本地模型/授权/helper也能调用；WS失败绝不fallback本地。全局--remote显式启用，令牌/会话不在argv或Debug。默认state目录在现有MCC_CONFIG_DIR，仅配置session管理，不创建本地runtime。image缓存同一私有客户端目录。

依赖B独占修改：最小tungstenite（官方当前修复版本、Rust1.89兼容，固定版本）及确需的信号处理库。TLS继续用Task1 rustls配置，不加自动redirect/proxy/insecure。限制头8KiB、JSON/frame64KiB、认证前连接8/5秒、认证后4、动作1、IP/全局认证预算、有界请求速率和session表、禁压缩/未masked帧。

## 执行裁决

- Ruling: 增加仅Host本地的host recover命令 — 无原控制条的setup失联及Host重启必须有明确的人为恢复入口；绝不暴露到WS。
- Ruling: 正常完成ACK后不把每个CLI退出视为控制连接释放 — 否则连续命令无法工作且可能清除暂停。
- Ruling: 客户端暂不跨平台发布；所有模拟测试只loopback/fake — 用户明确双端Mac，缺少第二台机器不阻止代码和模拟验收，但真实双机/公网必须单列未验收。
- Ruling: 只在全部CLI/Host/client路径连通后改0.3.4版本并打包 — 防止旧版本安装payload被覆盖。

## 实现中接口补充

- 后端operation字符串冻结为外层请求sequence的十进制u64；原请求id和socket ticket不变。每次释放后新控制claim换新的Host私有owner capability，后端按owner高水位防重放，不维护永久4096停机表。
- owned只读status/apps/windows/permissions false/observe由共享execute_remote_request内部受owner校验的Read context分派，不reserve输入epoch，不改变USER_PAUSED，也不自动start新helper；原Helper丢失仍要求恢复。
- HTTP升级5秒采用底层绝对deadline；应用Hello/session、活动RPC/图传/ACK也必须有绝对期限，不能因TLS/WS内部碎片读取不断重置单次timeout而无限延长。
