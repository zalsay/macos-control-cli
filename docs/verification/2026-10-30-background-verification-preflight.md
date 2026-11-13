# 第十三批收口：后台验证入口安全门与真实 G0 预检

日期：2026-10-30（Asia/Shanghai）。分支 `mcc-safarier`；HEAD `2f32d21248deaffd8c8c1152a39912aa46350c7e`，未提交/推送/安装/发布。

**结论：入口安全修复及三轮无 GUI 测试通过；实际 G0 仍 blocked。尚不能宣称可在日常桌面启用后台鼠标键盘控制，更没有完成正式不干扰验收。**

## 1. 本轮范围与实现

沿用原验证入口，不新增一套验收框架，也不改生产 `Sources`、`Package.swift`、原 App 打包脚本或任一 shipping admission。

- `/Volumes/RC500/dev/safarier/scripts/verify-background-input.sh`：只转发原 matrix，在完整参数检查前不再执行 native 测试或构建。无参数明确拒绝，help 不构建/运行任何 App。
- `/Volumes/RC500/dev/safarier/scripts/background-input-probe/matrix.py`：必须二选一 `--preflight` 或 `--isolated-ui`。prefix、rounds、states 和输出冲突先验证；已有输出不覆盖，已有输出父目录的符号链接/非目录拒绝，新目录按 0700 创建，原目录不擅自 chmod。构建异常写入失败 summary，不继续打开 probe。
- 同一 matrix 的 `--preflight`：只执行六个有超时、stdout/stderr/退出码记录的工具链探测。child 的 HOME、scratch、cache 与 module cache 使用私有临时路径；退出后移除。这里的 `sandboxedHome` 只代表 child HOME 重定向，不是 OS 安全沙箱。
- 预检记录并移除 child 环境的 `SWIFT_EXEC_MANIFEST`，包括空值；若调用者设置过 override，状态仍为 blocked，不把替代编译器/修补 manifest 的结果当作默认工具链通过。compiler/manifest/typecheck 统一经 xcrun，保留原 DeveloperDir/SDK 配置，不修改全局选择。
- `/Volumes/RC500/dev/safarier/scripts/background-input-probe/run.py`：显式要求 `--isolated-ui`，验证 visibility、label 与输出父链后才允许原诊断启动。保留已有 LaunchServices/PID 超时清理，不把其按命令行匹配的旧机制包装成正式 owned G1/G3 证明。
- 诊断 report/launch/matrix 均明确 `operatorConfirmedIsolation=true`、`isolationVerified=false`、`formalAcceptance=false`、`shippingAdmission=false`。隔离参数只是操作者确认，不是本机环境隔离的技术证明；诊断 bundle 也不是正式 Safarier receiver，不能用其结果授予 G2/G5。

实现者：Terra/high worker `01a18a44-9b6f-7e51-aa19-51af9ea81f68`，五个有效 turn_context 均核实为 `gpt-6.1-terra / high`。仅主 agent 做设计判断、code review 与独立复核；未使用 reviewer 子代理。主 agent 要求修正 override 执行风险、xcrun/cache 一致性、父链检查、失败报告、空 override 与异常输出编码。worker 最终冻结，未运行真实 GUI。

## 2. 证据与重复验证

证据根目录：`/Volumes/RC500/dev/safarier/.build/automation-stage13-main-review/`。

- worker 保留 RED/GREEN 与两轮修正日志：`/Volumes/RC500/dev/safarier/.build/automation-stage13-worker/`。RED 在私有镜像里拦截原 GUI 入口，没有为取红运行真实 probe。旧修正轮是 8 方法；最终 `REVIEW2-GREEN.log` 为 **10 方法**。
- 新测试：`/Volumes/RC500/dev/safarier/scripts/automation-core-tests/test-verification-entry-safety.py`。主 agent 在冻结 249 个代码/测试/脚本文件后，连续三轮各 **10 个测试方法通过**；所有 native/build/open 均在私有镜像里替换或拦截。
- 主 agent 独立 harness：`/Volumes/RC500/dev/safarier/.build/automation-stage13-main-review/IndependentEntryChecks.py`，三轮各 **40 项检查通过**。覆盖 help/noargs/非法参数零命令、预检白名单、预检绿仍 unverified、非空/空 override 清除且拒绝、既有报告保全、符号链接父链拒绝；设置真实 open tripwire。与 worker 测试分开记录，不将两者相加冒充生产验收数量。
- `bash -n` 及三个 Python 文件 AST parse 通过，未生成新的源码区 bytecode。
- 生产 Sources/Tests 与 Package 未修改。本轮未重跑第十二批完整逻辑套件；第十二批收口只核对历史三轮每轮 2,429 checks 的保存证据，见 `/Volumes/RC500/dev/safarier/docs/verification/2026-10-30-owned-background-startup.md`。

## 3. 实际 G0 预检结果

主 agent 先直接执行默认 manifest / XCTest typecheck，再通过修复后的实际入口执行：

```sh
/Volumes/RC500/dev/safarier/scripts/verify-background-input.sh --preflight --prefix g0-20261030-main
```

入口退出 **1**，符合 blocked 结果；不是入口测试失败，也不是工具链已修复。实际报告：`/Volumes/RC500/dev/safarier/.build/mcc-safarier-probe/g0-20261030-main/summary.json`。

| 探测 | 当前结果 |
| --- | --- |
| xcode-select -p | exit 0，`/Library/Developer/CommandLineTools` |
| xcrun --find swiftc | exit 0，`/Library/Developer/CommandLineTools/usr/bin/swiftc` |
| xcrun --show-sdk-path | exit 0，`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` |
| xcrun swift --version | exit 0，Swift 6.3.3，swiftlang-6.3.3.1.3 / clang-2100.1.1.101，target arm64-apple-macosx26.0 |
| 默认 swift package dump-package | exit 1，PackageDescription.Package 初始化符号链接缺失，Undefined symbols for architecture arm64 |
| swiftc -typecheck（仅 import XCTest） | exit 1，no such module XCTest |

`overrideDetected=false`；没有使用本项目自建 manifest wrapper 或修补 overlay。SwiftPM 自己产生的正常临时 `-vfsoverlay` 仍可出现在错误命令中，不将其误报为用户 workaround。预检 child 临时 HOME/cache/source 已清理，日志保留当时路径用于诊断。

仅做过有限只读候选查找，未发现可配置的 Xcode/VM 候选；`/usr/bin/xcodebuild` 文件存在不等于完整 Xcode 可用，不据此断言机器上绝对没有 Xcode 或虚拟机。未下载/安装/切换任何工具链或虚拟环境，也未修改系统 SDK/权限。

## 4. 安全边界、保全与未验收项

本轮实际预检只执行六个非 GUI 子命令；未执行 `swift test`、测试发现、release/打包/签名、真实 `--isolated-ui`、App/probe、AppleEvents、原生页面输入、System Events、全局输入、光标移动、焦点切换、真实 Profile、Keychain 或真实代理。没有引入全局输入兜底，也没有用“恢复焦点”掩盖抢占。

最终审计：`/Volumes/RC500/dev/safarier/.build/automation-stage13-main-review/final-review.json`。276 个既有文件保留，限定修改 4 个（原三个验证入口与正式计划）；新增安全测试和本报告共 2 个，合计 278 个。249 个冻结代码文件未变；前一批 248 个冻结代码中仅本批授权的三个入口发生变化。branch/HEAD、staging、兄弟仓库状态、10 个既有缺失资源、DeveloperDir 与 5 个受保护工具链文件 hash 保全，没有本轮 fixture 遗留。

审计夹具的首轮失败另存于 `final-audit.stderr`：主 agent 最初用 `git ls-files --deleted` 对照这 10 个稀疏缺失资源，但该命令不列出 skip-worktree 路径。核实它们均为原有 `S` 项且磁盘仍缺失后，仅把审计改为遍历 tracked 路径检查物理存在性；没有恢复资源、修改 index 或放宽生产检查。修正后的日志为 `final-audit-corrected.*`。

G0 还包括原完整 XCTest、release、原打包/签名等流程；即使六项预检全绿，也只能 `g0Status=unverified`，不能宣称 G0 通过。本次六项尚有两项失败，故为 blocked。G1–G5、正式 receiver、真实悬停/按住/拖动及人在其它 App 连续操作时的无干扰验收均未由本轮证明，所有生产门禁继续关闭。

## 5. 下一轮应做什么

优先确定一套 compiler / SDK / ManifestAPI / XCTest 配套、且原流程可复现的 DeveloperDir，并落实隔离 macOS 图形验收环境；不要求一定安装完整 Xcode，但不能拿不匹配的 CLT 或临时修补当作原流程通过。工具链变更或安装需单独授权。

环境就绪后先重复此无 GUI 预检，再在隔离环境执行原完整测试、release/原打包签名及最简 Profile 的正式闭环，逐项记录启动/接收者归属、退出、页面真实行为及用户输入非干扰。不得直接在日常桌面运行 `--isolated-ui`，也不能再以增加纯逻辑测试数量代替这一步。
