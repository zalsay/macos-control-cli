# Xcode 安装后的 G0 复核：默认工具链和原目标编译通过，未运行 GUI 测试

日期：2026-10-30（Asia/Shanghai）。仓库 `/Volumes/RC500/dev/safarier`，分支 `mcc-safarier`，HEAD `2f32d21248deaffd8c8c1152a39912aa46350c7e`。

**最新结论：原有 manifest / XCTest 组件阻塞已解除；正式 Debug、Release 及全部四个原测试目标编译通过。但 G0 仍为 unverified，不能当作原完整测试、App 打包签名或 G1–G5 已验收，更没有开放生产后台输入。**

## 1. 环境与执行边界

用户已取消虚拟机方案，自行安装 Xcode 并完成许可确认。本轮使用已选中的 `/Applications/Xcode.app/Contents/Developer`，Xcode 27.2（27B52），Swift 6.4.2（swiftlang-6.4.2.1.9 / clang-2100.4.1.1），SDK 来自该 Xcode 的 MacOSX.platform。只为子命令显式设置 DEVELOPER_DIR，未切换全局 xcode-select，未修改系统 CLT、SDK、权限或执行 sudo。

`xcodebuild -checkFirstLaunchStatus` 初次与最终均 exit 69、stdout/stderr 均为空；不能用“没有输出”当作 exit 0。主 agent 已更正初次口头的无报错表述。Xcode help 将此命令描述为检查是否还有 First Launch 任务；本报告不宣称整套 Xcode 首次初始化完成。本轮不代执行会安装组件并处理许可的 `-runFirstLaunch`。此状态与下述已实际通过的 Mac SwiftPM 编译分别记录。

证据目录：`/Volumes/RC500/dev/safarier/.build/automation-xcode-g0-20261030/`。

## 2. 原预检误报与最小修正

安装 Xcode 后，未修改的原预检已能默认解析 Package，exit 0；但 bare `xcrun swiftc -typecheck` 仍报 no such module XCTest。只读查找确认该 Xcode 实际已包含 XCTest.framework 和 XCTest.swiftmodule；主 agent 用同一编译器追加该平台真实的 `-F Developer/Library/Frameworks` 与 `-I Developer/usr/lib` 后，import XCTest 实测 exit 0。初次失败保留于 `preflight-initial.*`，独立成功保留于 `explicit-xctest-import.*`，不将误报继续归因于安装缺失。

Terra/high worker `01a18aaa-50c6-7621-b450-b1837e84232b` 只修改两处已有文件；主 agent 独立完成全部 code review：

- `/Volumes/RC500/dev/safarier/scripts/background-input-probe/matrix.py`：新增记录 `xcrun --sdk macosx --show-sdk-platform-path`；仅接受本次成功得到的单一绝对 MacOSX.platform 路径，验证平台、Frameworks 和 module 目录存在，拒绝空值、多行、相对路径、错误平台名、上溯路径、查询失败/超时。否则跳过 typecheck 并记录原因，不伪造通过。XCTest 命令显式绑定 `--sdk macosx`，正确传递含空格路径；新增保存所有探测 command argv。
- `/Volumes/RC500/dev/safarier/scripts/automation-core-tests/test-verification-entry-safety.py`：沿用原私有 mirror/stub 测试，新增上述回归。RED 实际捕获原命令缺少 -F；第二轮 RED 捕获缺少显式 SDK 前缀，均不是缺文件/语法错误。worker 日志在 `/Volumes/RC500/dev/safarier/.build/automation-xcode-g0-worker/`。

没有新增验证框架、替换 XCTest、使用 manifest wrapper/interface overlay，或放宽 help/noargs/输出保全、private cache、override 拒绝、隔离确认与 admission 规则。全部预检绿仍只能 unverified。worker 两个有效 turn_context 均为 Terra/high，已冻结并关闭；无 reviewer 子代理。

## 3. 本轮新鲜验证结果

| 验证 | 实际结果及范围 |
| --- | --- |
| 修正后真实 preflight | 连续三轮 exit 0，每轮七项子探测均 exit 0，无 timeout；defaultManifestStatus / xctestStatus 均 passed，g0Status 仍 unverified |
| 主 agent 重跑原入口安全回归 | 三轮各 15 个测试方法通过；所有 UI/native/build/open 都在私有镜像中替换/拦截 |
| 主 agent 独立平台 harness | 三轮各 42 项通过；显式 macOS 绑定、带空格路径、非法/失败平台、缺目录、typecheck 失败、override 清除且拒绝、重复报告与输出符号链接保全；仅 stub 子探测，GUI/build 命令禁止 |
| 原正式 Debug 产品 | 全新独立 scratch/cache，`swift build --product Safarier --jobs 2` exit 0，无 warning/error |
| 四个原测试目标，仅编译 | `swift build --build-tests --jobs 2` exit 0，无 warning/error；Core、Network、WebKit、App 四个 XCTest bundle 均存在，未运行任一测试本体 |
| 原正式 Release 产品 | 同一独立 scratch/cache，`swift build -c release --product Safarier --jobs 2` exit 0，无 warning/error |
| 构建产物检查 | Debug/Release 均为 arm64 Mach-O；裸产品 codesign --verify --strict 各 exit 0，不等于原 Safarier.app 打包/签名验收 |
| 入口语法 | bash -n、Python AST parse 通过，不在源码区生成 bytecode |

三轮真实 summary 分别位于 `/Volumes/RC500/dev/safarier/.build/mcc-safarier-probe/xcode-20261030-final-1/summary.json`、`/Volumes/RC500/dev/safarier/.build/mcc-safarier-probe/xcode-20261030-final-2/summary.json`、`/Volumes/RC500/dev/safarier/.build/mcc-safarier-probe/xcode-20261030-final-3/summary.json`。四个安全/验收字段始终 false：GUIExecuted、fullSwiftTestRun、formalAcceptance、shippingAdmission。

原构建命令、退出码、完整 stdout/stderr，以及 `/Volumes/RC500/dev/safarier/.build/automation-xcode-g0-20261030/build-artifacts.json` 保存可复查路径和产品 hash。没有执行新编出的二进制，也没有用 --list-tests / 测试发现加载测试包；15/42 的运行次数不是 Swift XCTest 运行数量。

## 4. 保全与未执行项

冻结 249 个代码/测试/脚本文件后验证，后续无漂移。279 个开始时已有文件全部保留，限定修改两个验证文件与正式计划共三处；新增本报告一处。177 个 Sources/Tests 文件、Package、原打包脚本、默认脚本/native/factory/manager admission 全部内容不变。兄弟 chrome-control-cli 的 dirty 状态、10 个原 skip-worktree 缺失资源、branch/HEAD/staging 与本轮开始时的 DeveloperDir 保全。最终审计：`/Volumes/RC500/dev/safarier/.build/automation-xcode-g0-20261030/final-review.json`。

未运行原完整 swift test、App/probe、真实 isolated-ui、AppleEvents、网页原生输入、全局鼠标键盘、真实 Profile/Keychain/代理；未继续虚拟机下载或启动，也没有删除此前留下的私有准备目录。未执行原 App 打包脚本、安装、发布、commit 或 push。裸 Mach-O 签名检查不冒充 App 内 helper/资源/原打包链验收。

## 5. 下一步

工具链组件不再是先前的两个阻塞点。后续仍需检查 Xcode 剩余首次初始化任务，并在用户明确允许测试窗口/可能激活窗口的时间段执行原完整测试、原 App 打包签名，以及正式最小 Profile 的接收者、退出和真实悬停/按住/拖动/同时人工操作非干扰验收。已取消 VM，不再把隔离虚拟机列为强制工具；也不能偷偷在用户正常使用桌面时执行旧 AppKit 测试，或用全局输入兜底。
