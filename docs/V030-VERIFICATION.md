# v0.3.0 验证记录（2026-10-27）

历史快照：后续显式授权入口及Chrome实机布局已在[v0.3.1验证](V031-VERIFICATION.md)完成；下列“待授权”仅描述0.3.0阶段。

范围：通用模型配置与 Chrome新窗启动/左侧全高布局；基线HEAD `d8165e19dbb4b79fc6332512755040ae8c3f54d4`，`codex/jev-click-target` 上本会话未提交工作。未提交/推送/安装到用户当前命令路径。

## 模型与配置

- 配置/CLI/语义点击测试涵盖标准TOML、私有权限、脱敏、stdin、有界读取、符号链接拒绝、原子更新/并发写拒绝、profile切换、URL改变需重供key、每次调用读取最新配置、旧daemon门禁、动态模型响应校验。
- 真实 `/usr/bin/curl` loopback 测试按配置的完整路径POST并带Bearer，未将key放argv；不改写端点路径。原有取消、超时、错误响应及有界进程/管道清理回归仍保留。
- 已从用户当前 `.env` 单次通过stdin迁移 key，原文件不修改，`~/.config/mcc`0700、`models.toml`和`config.toml`0600。显示和日志不输出key。
- 从 `models.toml` 取得URL/key/model后完成一次真实OpenRouter合成OCR测试：请求 `typesafe/jev-1.13`，返回 `typesafe/jev-1.13-20260917`，选择t0，probability0.99/confidence0.98，1754ms。无桌面输入，单样本不是延迟或准确率基准。
- `cargo clippy --all-targets --locked --offline -- -D warnings` 通过。

## 工程验证

- `cargo test --locked --offline -- --test-threads=1`：148项真实测试通过，1项真实付费API测试默认忽略（前述已单独执行）。binary/doc-test入口的0 tests不计入数量。
- `bash tests/native-smoke.sh <0.3.0 helper>`：全部确定性BDD与172项无副作用JSONL检查通过，包含fresh/active/paused/cancel启动许可、双阶段receipt绑定、Desktop/Chrome两种scope、Retina/多屏坐标、宽1600/高8192和原有输入/焦点/文件面板门禁。
- 新增自动化权限检查的红/绿测试通过：未实现时编译缺少检查函数；实现后0/-600/-1743/-1744/未知状态分支与现有setup测试通过，不发送Apple Event或网站输入。
- `bash build.sh`、`bash tests/standalone-package-smoke.sh`、`bash tests/install-smoke.sh dist/copis-chrome-0.3.0-darwin-arm64 dist/copis-chrome-0.2.9-darwin-arm64` 通过。安装仅在临时HOME/prefix，覆盖升级验证保留旧版本全部文件，不修改用户PATH。
- 用户PATH当前安装仍为0.2.4，CLI/helper哈希在本轮前后相同；0.3.0是工作区新产物，未覆盖原安装。

## 实机验证：自动化授权待本人完成

1. 使用本任务私有runtime启动0.3.0 daemon，屏幕录制/辅助功能均true，未连接任何旧窗。
2. 首次新窗启动在AppleScript阶段20秒超时，没有新增Chrome窗口，原窗口ID/PID/bounds未变。独立无提示Apple Events授权检查返回-1744，仍需要本人授权；只读AppleScript也无法在5秒内完成，不能据此宣称创建/布局可用。
3. 增加不弹窗的自动化权限预检后，用最新0.3.0产物实测：95ms内返回 `AUTOMATION_PERMISSION_REQUIRED`，没有创建新窗，也未改变旧窗。未自动点击允许、不修改系统权限、不使用其他宿主/浏览器接口绕过授权。
4. 只停止本任务daemon，最终 `running:false, connected:false`；保留Chrome及账号状态。未发布、未上传、未发送网站输入。

**尚未通过的实机验收**：AppleScript创建receipt到CGWindow/AX的真实绑定、最终左侧全高布局回读、新窗原像素观察。请本人在系统设置“隐私与安全性→自动化”中允许当前宿主（实际显示的Codex/ChatGPT）控制Google Chrome后，再继续这些步骤。Rust fake Native和纯几何测试不能代替此验收。

本机私有证据：`/tmp/mcc030-layout-41koga4j/evidence/qa-summary.json`；原始窗口元数据不进入分发包。

## Code review与边界

主agent执行，不交给子代理。审查发现并要求修正：fresh helper没有input lease，不能直接用beginInput启动；使用与鼠标键盘不兼容的独立StartupPermit，仅允许无活跃lease且epoch/generation未变的窗口setup，不修改原输入门禁。创建receipt须绑定本次新窗，不能只凭唯一新增CG窗口猜测目标；主屏不使用随keywindow变化的NSScreen.main。复用原Desktop.axBounds，不叠加另一套AX几何读取；修正availableWidthPx为真正可用屏幕宽度。常规Swift鼠标键盘实现与HEAD逐字节一致，Rust Service::input与0.2.9源码逐字节一致。自动化权限缺失必须在创建/布局前明确拒绝。

未覆盖Intel/其他macOS版本/所有物理Retina多显示器组合、CI、签名公证。既有Rust管道清理时间断言在并行运行有偶发超时历史；本轮全套以串行执行为准，未声称修复该旧时序问题。启动/投递不证明登录等业务后置条件，不发布、不上传、不重置账号，不绕过暂停。
