# 0.3.4 远端模式开发与验证记录（2026-10-28）

**状态：0.3.4 代码开发、主 agent review、当前 arm64 Mac 上的自动化验证及 release 打包完成；未做真实双 Mac / 公网桌面验收，未部署或发布。**

基线为已发布 0.3.3 的 `d6f8e37f903433334f472c440588c1fad510b727`；当前分支 `codex/remote-host-v034`。Cargo.toml / Cargo.lock 已更新为 0.3.4，本记录描述提交前验证，后续提交/推送/部署状态以实际Git和独立部署记录为准；不把本记录当作GitHub tag/Release或公网安全认证。

本记录取代早期“基础阶段、远端尚不可用”的检查点。2026-10-28 恢复开发时，旧 `/tmp` 日志已不存在，因此以下结果均重新执行，不沿用早期的 211 / 305 项统计。

## 最新补充：修复包的本机真实 Host / Client 两轮复测通过

2026-10-28，用户要求测试新包。主 agent 核对本轮旧 Host 进程身份后停止它，在**同一 Host 状态目录**执行本地恢复，确认旧私有 daemon `running:false`，再启动修复包的 Host/helper；旧客户端缓存保留，在已完成本地恢复后明确重新配对新 boot，没有删除状态或换 runtime 绕过暂停。

- 实际 WSS：`wss://127.0.0.1:49250/mcc/v1`，CA/token认证；真实 Swift helper / Chrome / OCR / OpenRouter，不是fake。
- **连续两轮**显式 `chrome start --profile mcc` → observe/下载 → click-target → 后置观察均通过。回执确认 `mcc / Profile 2`，两次新窗口ID分别711、725，1600×1335、贴左/满可用高度；本轮未再出现 `CHROME_LAYOUT_READBACK_FAILED`。
- Host 实际调用 `typesafe/jev-1.13`，回执模型版本 `typesafe/jev-1.13-20260917`；两次选中 `t11 / 运行远端测试`，决策分别1623ms、2213ms。模型选中ID后仍走原点击链，没有增加OCR复核。
- 两个独立测试页各记录**恰好1次点击**，后置OCR均显示“成功：已点击1次”，不是只凭 `sent:true` 判定业务效果。
- 第一轮还验证了坐标点击输入框、type `mcc-wss-034-okX`、press Backspace；页面事件和真实截图确认最终值为 `mcc-wss-034-ok`。
- Client未启动本地helper/runtime，模型在Host解析；用户MCC配置/.env哈希未变。私有回执、前后截图及事件证据见 ignored `target/v034-profile-live-retest/`，不进入产品包。
- 操作验证完成后，用户人工接管触发暂停，网络disconnect被 `USER_PAUSED` 拒绝；没有重试输入。清理按“停止本轮Host → 停止本轮私有daemon → `running:false` → 原状态目录本地恢复”完成，并停止测试页服务，不再占用桌面。没有结束用户Chrome或其他daemon。

**验收边界：** Chrome进程在这两轮开始前已运行；第一轮加载了新helper，第二轮复用同一helper，原连接正常disconnect后重新创建lease。两轮通过证明显式profile的新窗口完整操作链，不等于“退出整个Chrome进程后再冷启动”验收；没有为制造冷启动而退出用户浏览器。真实双Mac/公网、x64仍未验收。

### 本次修复与此前失败

此前第一次显式profile启动创建窗口但在AX回读失败；用户同时说明另一次 `FOCUS_LOST / USER_PAUSED` 是自己操作鼠标，因此没有放宽焦点/暂停门禁。

主 agent 用原源码 `ChromeDesktop.axBounds` 对原失败窗口做只读探测：同一PID/CGWindowID连续回读正常，AX与CG一致；当时具体底层AX错误码未捕获，不能据此断言具体OS错误。原稳定轮询遇首次AX失败立即退出且复用变更前AX元素。Terra在原方法内修正为原两秒预算内精确重取原窗口并只重读类型化暂不可用；仍需两次AX/CG稳定匹配，不重写几何或重放启动，暂停/取消/身份/类型/几何/宽度错误继续拒绝，主agent完成唯一review。

回归先出现行为RED，修复后GREEN；主agent完整native-smoke（含原chrome-start子进程测试、原门禁BDD、新readback及186项JSONL）、Rust1.89全量321通过/1忽略、Clippy/fmt、release/独立包/临时安装与17项WSS黑盒均通过。修复证据在 `target/v034-profile-fix/`；新只读原语亦在原失败窗口取得两次真实稳定样本。该只读probe与上述后来完整两轮实机验收是不同证据，不混同。

## 1. 实现与分工

用户指定尝试 `terra-worker` 写代码、主 agent review。实现阶段使用自定义角色，核对首 worker 实际 turn_context 为 `gpt-6.1-terra` / high；没有建立 Runner mission。所有代码 review、集成裁决和最终复验均由主 agent 完成，没有委托子代理 review。

- A `01a17cac-07b5-78c3-a64b-a2c52e5b3bdf`：私有凭证与存储原语、共享执行入口、daemon / native / Jev 请求取消与 Swift 保持暂停。
- B `01a17cb0-34e6-7630-b6c5-75f05fff2098`：协议 / 会话、TLS / WS 边界、客户端和私有会话缓存。
- C `01a17cd9-e49d-7363-8911-6a592c7df578`：CLI 参数路由、Host 命令与有界图片传输。
- D `01a17cdc-870e-7a92-bdeb-03d7206f839b`：真实 CLI / WSS 进程测试及隔离 fake native / Decisions。
- E `01a17d04-0cb4-7520-9b29-31ac8d49bc2f`：前台 Host、受控恢复、执行器接入和运行期集成测试。

当前生产路径为 `main → remote client / Host → execution → 原 daemon / Service → 原 Swift helper`。客户端不启动本地 helper、不读取本地模型、不在连接失败时回退到本地输入。模型配置、OCR、Jev 和输入只在 Host；`click-target` 继续给模型 target 与候选 ID / 文字，按所选 ID 查同帧坐标走原点击链，没有重新加入 OCR 复核。

已实现 `host tls init` / `host token init` / `host start` / 本地 `host recover`，以及 `--remote` / `--ca-cert` / `--token-file` / `--remote-state-dir`。完整操作方式、可信分发与轮换见 [远端使用指南](REMOTE-HOST.md)。

## 2. 主 agent review 收口

主审逐项核对批准规格和生产调用链，修正通过原实现 worker 完成，再独立重跑。重点包括：

1. 证书链、IP / DNS、期限、错私钥与显式 CA 加载校验；凭证私有存储、不覆盖、脱敏及安全随机 token。
2. 仅 WSS、固定路径 / 子协议、Bearer、拒绝 Origin、无 insecure / proxy / redirect 降级；握手、头、帧、连接、速率、缓冲和绝对时间上限。
3. 单控制 owner、socket 内部 ticket 与准确匹配 ACK；正常短命 CLI 结束不清 lease，失联不能通过换 session / helper 或重连消除暂停；回执缓存与序号表有界、不重复投递。
4. 原 Service 主锁外的每请求取消与匹配侧带 ACK；模型等待中可取消，原 Swift lease / pause / epoch / 三秒倒计时仍生效。daemon 用内核 peer PID、UID、启动身份及独立 watchdog 检测 Host 死亡，不能只依赖 Host Drop。
5. 本地恢复核对原 owner / daemon / helper，不能误杀或接管他人进程；首次 connect 失败且确无 lease 时安全释放，原有暂停不因此重置。
6. 只读观察在暂停时仍可用；semantic-click 内部帧登记、缓存重放不重复截图 / 点击，失效帧返回已确认的错误，不复活 / 挤掉新帧。
7. 注册帧的有界二进制下载，真实本地 imagePath，已有输出不覆盖；本地输出竞争与传输失联区分，正确 ACK 后返回 OUTPUT_EXISTS。
8. select-file 默认关闭，Host 显式允许根后才开放；路径属于 Host，没有通用上传 / 任意路径下载或远程配置 / 授权 / 恢复入口。

此前自动化阶段主审未留待修复的已知阻塞项；其后真实桌面测试发现的profile回读问题已修正并完成上述两轮同机完整复测，整个Chrome进程的冷启动仍待独立验证。以下验证不构成未知漏洞不存在或独立渗透测试的保证。

## 3. 本轮实际验证

可复现日志位于项目 ignored `target/v034-verification-20261028/`，不进入产品包。隔离工具链位于 `target/mcc034-rustup`；没有修改全局 Rustup 默认版本。

| 检查 | 本轮结果 | 日志 |
| --- | --- | --- |
| 真正 Rust 1.89.0 全量 `cargo test --locked --offline -- --test-threads=1` | **321 passed，0 failed，1 ignored** | cargo-test.log |
| 同工具链 `cargo clippy --all-targets --locked --offline -- -D warnings` | 通过 | clippy.log |
| 同工具链 `cargo fmt --all -- --check`、`git diff --check` | 通过 | fmt.log、diff-check.log |
| `bash tests/native-smoke.sh` | 原生纯 BDD 与 **186 项无副作用 JSONL** 通过 | native-smoke.log |
| Rust 1.89.0 `bash build.sh` release | arm64 CLI 三入口 / Swift helper / 签名 / 归档通过 | build.log |
| `bash tests/standalone-package-smoke.sh` | 包内源码、文档链接、入口 / helper、SHA256 与无运行数据检查通过 | package-smoke.log |
| 临时 HOME / prefix `install-smoke.sh`，从 0.3.3 升级到 0.3.4 | 通过；旧版文件保留，无真实安装变更 | install-smoke.log |
| 指定包内 release `mcc` 的 `remote_process` 测试 | **17 / 17 通过**，非仅 debug binary | release-process.log |
| Cargo.lock 全部 registry 版本 OSV 批量查询 | **133 包，查询完整，无已知 advisory 命中**；不是完整 cargo-audit 或未知漏洞保证 | dependencies.json |

唯一 ignored 项是原有真实付费模型 API 测试；本节自动化不调用真实模型。上方随后授权的实机复测通过Host的models.toml实际调用了OpenRouter两次，不与fake自动化混同。native BDD 包含保持暂停、恢复倒计时、迟到 epoch、原窗口 / 焦点 / 文件弹窗 / profile / 截图边界；没有投递真实系统输入、申请 TCC、激活 Chrome 或截图。

### 真实进程验证的含义

测试实际启动独立 CLI 进程和真实 TLS / WSS Host，进入原 daemon / Service；桌面 helper 与 HTTP Decisions 为隔离 fixture，不是实际 Chrome 或云端 Jev。覆盖：

- 错 CA / token 在任何 Host daemon 启动前拒绝，客户端无 helper / model / runtime，也不 fallback。
- 跨 CLI 进程 connect → observe / 下载 → click，原 frame / connection 保留；Host 模型禁用生效。
- 模型启用时一次 OCR / 一次本机 fake Decisions / 一次原点击，内部选中帧可继续供 press / type 使用；Host key 不进 WSS。
- 模型等待中杀客户端，取消模型进程并保持原暂停；之后输入拒绝，但只读 observe 仍可用。
- 并行 session 不窃取控制；首次 connect / claim 失败不接管现有本地连接；Host 重启不能隐式恢复。
- select-file 未设置允许根时拒绝，允许根内成功，越界 / symlink 逃逸拒绝。
- 原请求回执重放不重新观察 / 点击；已删除或淘汰帧返回 ACKed 错误，不复活旧帧或造成假失联。
- fixture 清理仅对捕获并匹配的 UID / 启动时间 / 进程组操作，不凭 stale socket 或猜测 PID 杀进程。

### 复跑命令

在仓库根目录执行（工具链先准备于 ignored target）：

```sh
export RUSTUP_HOME="$PWD/target/mcc034-rustup"
export CARGO_TARGET_DIR="$PWD/target/mcc034-msrv"
rustup run 1.89.0 cargo test --locked --offline -- --test-threads=1
rustup run 1.89.0 cargo clippy --all-targets --locked --offline -- -D warnings
rustup run 1.89.0 cargo fmt --all -- --check
git diff --check
bash tests/native-smoke.sh
RUSTUP_TOOLCHAIN=1.89.0 CARGO_NET_OFFLINE=true bash build.sh
bash tests/standalone-package-smoke.sh
bash tests/install-smoke.sh "$PWD/dist/copis-chrome-0.3.4-darwin-arm64" \
  "$PWD/dist/copis-chrome-0.3.3-darwin-arm64"
MCC_REMOTE_TEST_CLI="$PWD/dist/copis-chrome-0.3.4-darwin-arm64/mcc" \
  rustup run 1.89.0 cargo test --locked --offline --test remote_process -- --test-threads=1
```

### 部署提交前的测试夹具稳定性检查

用户随后授权推送开发分支并在另一台Mac构建部署。主agent再次运行全量时，原owner死亡测试在fake helper首次Claim握手阶段出现一次CANCEL_UNCONFIRMED，尚未执行owner死亡断言；定向独立复跑10/10通过。通过注入2.2秒fake启动延迟，可确定性复现同类2秒握手超时，但不能据此认定原偶发失败的唯一底层原因。

修正仅在 `src/daemon.rs` 的 `cfg(test)` Fixture：用原Helper::request发送只读permissions握手，在原3秒fixture预算内等待fake就绪；不重试Claim、不增加生产超时、不改变lease/phase/epoch。新例验证延迟启动后首次Claim及初始状态，主agent对照旧包源码确认daemon生产区段逐字节不变。新增回归先RED后GREEN，原owner死亡与旧helper拒绝用例亦通过。

主agent随后重新运行真正Rust1.89全量：**322通过、0失败、1原付费API测试忽略**，全targets Clippy、fmt/diff通过；前文321项是新增该夹具用例前的历史统计，不混作最新计数。此前真实桌面验证的Swift源码未变化。证据保存于ignored `target/v034-remote-deploy/`，不进入Git或分发包。

## 4. 保护范围与交付

本轮开始前记录已有分发包、实际安装与用户配置 / `.env` 的哈希；结束时对 **2391 个文件**核对未变，同时核对 HEAD / 既有 tags。源码与新归档扫描实际已配置 secret 值，无命中；新包不夹带 `.env`、models.toml、私钥 / token、运行帧或 runtime。证据为 preserved.json / preservation-scan.json；这些本地文件不打包。

产物：`dist/copis-chrome-0.3.4-darwin-arm64/`、同名 `.tar.gz` 与 `.sha256`。最终文档同步后重建并重跑包检查；没有覆盖旧版本包，也没有替换真实已安装 mcc。测试临时资源已回收；没有在本机启动公网监听。此前本机测试阶段未做提交/推送/发布；用户随后另行授权推送开发分支和远端构建部署，未授权本次自动合入main、打tag或创建Release。

## 5. 明确未验收与已知边界

- **未验收**：第二台真实 Mac、整个Chrome进程退出后的显式profile冷启动、人工暂停后原控制条继续的全链、实际公网 / NAT / 防火墙、真实 x64 机器或 x64 构建。loopback / fake 不替代这些验收。需提供受控 Host 与人工配合后另做。
- Host 需要已登录且可操作的 macOS 用户桌面，不能据本次验证承诺锁屏、睡眠或无显示环境可用；证书有效期依赖两端正常系统时间。
- 默认32图上限覆盖登记的自动缓存；SIGKILL / 断电发生在创建图片与登记身份之间可能留下未登记 orphan。为保护未知用户文件，不按后缀扫删，因此不是任意崩溃下的全磁盘配额。显式 --out 不自动删除。
- select-file 的 canonical-root 检查不是 OS 文件沙箱；本地同权限进程在检查与原生选择之间替换文件仍有 TOCTOU 边界。允许根不应交给不可信本地进程写入。
- JPEG做协议/结构/尺寸/摘要校验，不是完整像素解码；本机真实截图下载和显示已验证，真实双机传输仍待验收。
- token 是远端桌面控制凭证，不是 Jev key。只可信分发 CA 公共证书与 token，私钥不外传；不要向不可信操作者开放。输入 sent:true 只表示投递，不代表业务 effectVerified。
