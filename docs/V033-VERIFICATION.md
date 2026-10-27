# v0.3.3 模型启用/禁用验证（2026-10-27）

基线：0.3.2 已按用户要求单独提交为 `33fdebbe98be385f46629495377fcde21d709438`（`feat: support named Chrome profiles v0.3.2`），工作区干净后建立 `codex/model-toggle-v033`。本文记录提交前实现与验证；用户随后要求重新测试构建、提交0.3.3并本地合入main，实际提交/合入SHA以Git历史和交付回执为准。本次不自动推送、打tag或安装，未修改已发布0.3.1标签。Code review由主agent执行，未委托子代理。

## 改动范围

- 复用现有 `models.toml`、`Store::execute`、`Store::resolve_model`、私有权限/写锁/原子写入，不新增独立配置文件或模型调用链路。
- 每个模型profile新增严格布尔 `enabled`，省略默认为true。`--config enable <name>` / `disable <name>`支持三个CLI入口；回执/列表/详情显示状态且key脱敏。
- 保留URL、key、model、默认选择与Chrome配置；重复切换幂等，未知名称或写锁冲突明确失败；更新模型设置不改变已有禁用状态，改变URL仍须显式提供新key。
- 禁用默认模型时，新CLI `click-target`在daemon启动和原生/网络操作前返回 `MODEL_DISABLED`；临时key不能绕过，不切换默认、不降级点击。选择默认profile本身不启用它。
- 不追溯取消已开始的请求，不把本地配置开关当成供应商key撤销/全局急停。daemon不缓存或重复读取模型配置；内部Decisions协议、target+ID/文字请求、原点击链路和Swift实现不变。

## 已执行验证

- TDD：在0.3.2上新增9项测试，先观察到未知命令、缺失状态字段、缺少禁用拦截等预期失败，再实现。
- `cargo test --locked --offline -- --test-threads=1`：173项通过，1项付费真实API测试默认忽略；本轮未调用外部模型API。
- `cargo clippy --all-targets --locked --offline -- -D warnings`、`cargo fmt --check`、`git diff --check`通过。
- Store测试：新/旧配置默认启用；显式false；严格布尔类型；反复禁用/启用保留凭据/默认/Chrome设置；修改URL/key/model不重启用；不跨端点复用key；多profile无自动回退；default不隐式启用；坏参数、未知名称、锁冲突不改原文件；读取和错误不泄露密钥。
- CLI测试：mcc/desktop-control/copis-chrome均可本地切换；无runtime/helper启动；禁用模型时三入口各测试普通与 `--jev-key` 两种调用，均非零退出且返回 `MODEL_DISABLED`，runtime目录未创建，loopback监听器未收到连接，配置未被改写。
- 已有fake-helper链路：禁用模型后仍可connect/observe/坐标click；已有连接上的click-target仍被拒绝且不破坏连接或帧；原生USER_PAUSED仍映射为FOCUS_LOST/reason=USER_PAUSED；只停止本测试私有daemon。该测试不投递真实桌面输入。
- 实现中修正了测试夹具使用macOS长临时路径导致Unix socket路径验证先失败的问题：改用短 `/tmp` 路径，未放宽生产runtime限制。Clippy提出的 `is_none_or` 简化已采用并重新全量验证。

## 原生与安装边界

提交0.3.2前在本轮重新运行了全部native BDD与186项无副作用JSONL检查、164项Rust测试（另1项忽略）、Clippy、分发包及临时前缀安装/升级检查，均通过。0.3.3没有Swift变更，不重复操作Chrome，也不将前一版实机profile验收冒充本版新GUI测试。普通输入/窗口/焦点/暂停/倒计时/取消门禁未更改。

分发检查沿用 `build.sh`、`tests/standalone-package-smoke.sh`、`tests/install-smoke.sh`；安装检查仅使用临时HOME/prefix和私有runtime，不覆盖实际安装。模型测试全部使用隔离配置，不更改用户的API key、默认模型或启用状态。当前配置契约与回退旧CLI注意事项见 [模型配置](MODEL-CONFIG.md)。

## 提交与合入前构建复验（2026-10-27）

- 已刷新origin：本地main与origin/main均为 `d8165e19dbb4b79fc6332512755040ae8c3f54d4`，是本功能历史的祖先。因此本地合入还包含已有0.3.1和0.3.2，不是只合一个孤立的0.3.3补丁；最终Git状态以合入时复查为准。
- 在0.3.3当前源码上重新执行Rust全量173项通过/1项忽略、Clippy、fmt与diff检查；不是沿用先前结果。
- 重新构建release包，分发包源码一致性/文档链接/SHA256检查与临时HOME/prefix从0.3.2升级检查通过；未覆盖实际安装。
- 对打包的0.3.3 helper重新执行全部native BDD与186项无副作用JSONL检查，通过；未申请权限、激活Chrome、截图或投递真实输入。
- 三个release入口分别验证禁用（含临时key覆盖）时不创建runtime/helper或发送模型请求；启用后，真实CLI→私有daemon→本地loopback Decisions测试服务返回t0→原点击链路成功，选择同帧坐标(60,40)，换算屏幕坐标(130,70)。每次只有一次observe/一次模型请求，没有新增OCR复核；回执仍为 `effectVerified:false`。
- 在已有私有fake-helper连接上再次禁用，click-target被拒绝且连接/帧保持可用；原坐标click仍成功，原USER_PAUSED错误映射保留。所有测试私有daemon均disconnect/stop，最终 `running:false, connected:false`。这不是实机浏览器或真实付费Jev验收，不以fake输入冒充系统事件。
- 检查498项既有用户配置/.env、实际安装及旧0.3.1/0.3.2包文件哈希保持不变；已配置API key不在提交范围或0.3.3归档中，0.3.1标签保持不动。

本次私有命令日志及release端到端证据位于 `/tmp/mcc033-submit-main.AX1LIg`，不进入提交或分发包。Code review仍由主agent执行；合入后继续在main运行回归，不将提交成功当成合入验证成功。
