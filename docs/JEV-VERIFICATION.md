# Jev 语义点击工程验证记录

> 本文件是0.2.5直连TypeSafe实现的历史快照，不代表当前OpenRouter版本。0.2.6的实际在线验证、配置与边界见 [OpenRouter验证记录](JEV-OPENROUTER-VERIFICATION.md)。

日期：2026-10-26（Asia/Shanghai）。实现分支 `codex/jev-click-target`，基线 `d8165e1`，功能包版本0.2.5，协议版本1。代码尚未提交、合并、推送或安装到用户前缀。

## 已执行的工程验证

- 基线 `cargo test --locked --offline`：94项实际测试通过，退出0；不把各 binary/doc-test 的0项当作测试覆盖。
- 最终 `cargo test --locked --offline`：126项实际测试通过，退出0。分组为 lib65、application_scope10、behavior19、cli9、mcc5、review12、semantic_click6。
- 新增语义 CLI 测试：参数/帮助、缺失或非法 key 在启动后台前拒绝、显式值和两种环境变量优先级、旧 helper 拒绝、无密钥回显/日志/子进程环境继承。
- 新增服务夹具测试：一次决策和单次受守卫点击、原帧像素到屏幕坐标转换、云端请求不含路径/窗口标题/连接凭据、OCR 不足和模型失败不投递、原生拒绝不重试、模型等待后窗口几何重新检查。
- Jev 传输17项测试：HTTP状态映射、非法/超限 JSON、请求大小、stdin配置及转义、超时子进程回收、继承管道有界清理、取消前无启动/取消中回收、敏感环境清理。真实 `/usr/bin/curl` 对本机 loopback HTTP 服务验证 Authorization 与中文/引号/反斜杠/换行 JSON 原样送达；生产端点没有测试覆盖或实际请求。
- `bash tests/native-smoke.sh`：退出0，新增28项文字守卫检查、原有BDD与153项无副作用JSONL检查通过。含旧坐标点击兼容、文字/布局/尺寸变化、OCR不足、帧过期、暂停/继续换代旧结论拒绝、非法守卫与数值上限。离线真实 Vision OCR 沿用原测试，不采集用户屏幕。
- `cargo fmt --all -- --check`、`git diff --check`：退出0。
- `bash build.sh`：本机 arm64 release 功能包构建成功，Rust三入口、Swift helper、ad-hoc签名、源码和文档归档齐全。
- `bash tests/standalone-package-smoke.sh`：退出0，验证入口、协议元数据、源码一致性、文档链接、归档SHA256、不夹带运行数据。
- `bash tests/install-smoke.sh <0.2.5包> <0.2.4包>`：退出0，仅临时 HOME/prefix，验证安装/重装/同版本篡改拒绝/升级。旧版本文件保留且内容不变，私有 daemon 最终核对 running:false；没有改写用户PATH、安装目录或现有任务daemon。

本次初次原生 smoke 曾因编译期间文件仍在修改而中止；冻结原生源码后完整重跑通过，以上采用最终退出0的结果，不采用中间编译输出作为成功证据。

## 主 agent 审查与修正

所有 code review 均由主 agent 执行，worker 仅实现/测试 `src/jev.rs`。

- 复用既有 observe、service互斥、input坐标转换、Swift send/cancellation/焦点/指针校验，不建立旁路输入。
- 使用原 daemon stopping 信号取消模型传输，避免8秒网络预算拖过原5秒退出等待。
- 点击内的复核观察不覆盖当前点击操作提示；原本的独立 observe 保持原行为。
- key/target校验各用同一函数覆盖CLI与服务入口；密钥不进入帧、回执、helper请求或curl argv。
- 新守卫的 epoch 限制为 JSON 精确整数范围，避免 NSNumber 到 Int64 的边界转换陷阱。
- 校验模型完整候选概率分布、已选项、置信度一致性、存在性和OCR证据，不能把任意模型坐标直接送入输入层。

## 尚未验收的边界

- **未使用真实 Jev API key，未验证账户认证、真实远端TLS/API可达性、在线延迟或模型目标选择准确率。**
- **未执行真实用户桌面点击、浏览器业务流程或业务后置条件验收。** 工程夹具不等于实际按钮命中证明。
- 126项是Rust测试数，不包含另外列出的Swift纯逻辑/JSONL测试；不能据此承诺误点率或提速倍数。
- 初始阈值未经真实中文/英文窗口数据校准；严格整帧OCR布局一致性可能拒绝动态页面。
- OCR不证明控件角色、可点击性或启用状态；最终截图与点击不是原子操作。
- 未执行Intel原生构建、非Unix交叉编译、Developer ID签名/公证、CI或公开发布。
- `--jev-key`仅单次提供，不是持久配置；外部shell/Agent/进程工具记录不受本工具控制。

使用契约及隐私/错误说明见 [Jev语义点击](JEV-CLICK-TARGET.md)。真实使用应先在获授权、无破坏性的隔离窗口中验收，密钥通过本机安全渠道注入，不要贴进对话。
