# 2026-10-28 自动化 G0 工具链与工作区基线

## G0 结论：blocked

当前选用的 CLT SwiftPM 无法链接 5.10 manifest；在限定路径中未找到完整 Xcode；并且未执行隔离图形会话中的完整测试。没有进入 Task 1，没有开发或验证后台自动化功能。需要用户准备与当前 macOS/项目兼容、包含 SwiftPM、macOS SDK 与 XCTest 的完整 Xcode 工具链，并提供其 `Contents/Developer` 路径；之后仅在单条命令设置 `DEVELOPER_DIR` 重跑基线。完整 G0 验收还需要独立的隔离图形会话。此处未安装或修改全局选择。

## 已执行诊断

证据目录：`/Volumes/RC500/dev/safarier/.build/automation-task0/`（Git 忽略）。下列名称对应同名 `.command`、`.stdout`、`.stderr`、`.exit` 文件；输出为空也有单独文件。

| 命令 | 退出码 | 结果 / 证据前缀 |
|---|---:|---|
| `git status --short --branch` | 0 | `mcc-safarier`，已有 dirty 文件；`git-status` |
| `git rev-parse HEAD` | 0 | `2f32d21248deaffd8c8c1152a39912aa46350c7e`；`git-head` |
| `git diff --stat` | 0 | 2 个已跟踪文件，378 行新增；不包含未跟踪文件；`git-diff-stat` |
| `git diff --cached --stat` | 0 | 无暂存 diff；`git-diff-cached-stat` |
| 基于 Git 路径清单计算现有 dirty 文件 SHA-256 | 0 | 包含未跟踪文件，逐文件完整清单见 `dirty-hashes.stdout`；在新增本报告前采集 |
| `xcrun swift --version` | 0 | Apple Swift 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)，arm64-apple-macosx26.0；`swift-version` |
| `xcode-select -p` | 0 | `/Library/Developer/CommandLineTools`；`developer-dir` |
| `xcrun --find swift` | 0 | `/Library/Developer/CommandLineTools/usr/bin/swift`；`swift-location` |
| `xcrun --show-sdk-path` / `xcrun --show-sdk-version` | 0 / 0 | CLT `SDKs/MacOSX.sdk` / 26.5；`sdk-path`、`sdk-version` |
| `swift package dump-package` | 1 | manifest 链接阶段报 arm64 `PackageDescription.Package` 的 `swiftLanguageVersions: [SwiftVersion]?` 初始化符号缺失；完整日志 `dump-package.stderr` |
| `swift package --package-path .build/automation-task0/minimal-manifest dump-package` | 1 | 隔离的最小 5.10 manifest 同样报相同缺失符号；`minimal-dump` |
| `nm -gU .../ManifestAPI/libPackageDescription.dylib` + `xcrun swift-demangle` | 0 | 导出签名见 `manifest-symbols.stdout`；对比链接请求，证明当前接口/库符号不匹配 |
| Python 限定目录只读枚举 | 0 | `/Applications`、`~/Applications`、`/Library/Developer`、`~/Library/Developer` 中常见 Developer 路径未发现完整 Xcode；选中 CLT 的两个检查位置未发现 XCTest.framework；`toolchain-inventory` |
| `ls -la .build/mcc-safarier-probe` 及既有工具链证据只读检查 | 0 | 既有 probe 不作为 SwiftPM/G0 的替代；`probe-inventory`、`existing-toolchain` |

最小 manifest 使用同一 Swift tools 5.10 和 `Package(name:)`，不依赖 Safarier 业务源码，也重现同一个未定义符号，因此问题定位到当前 PackageDescription 工具链的接口/链接 ABI 不匹配，而非本项目业务测试失败或仅由项目 manifest 内容触发。现有证据不能确定底层安装损坏的具体原因，也不能排除后续修复工具链后其他源码问题。`DEVELOPER_DIR` 和 `TOOLCHAINS` 未设置；没有找到可验证的完整 Xcode，因此没有执行替代 Xcode 重试。

## 未执行 / 阻塞测试

- `swift build --build-tests`、`swift test --filter 'SafarierCoreTests|SafarierNetworkTests'`、`swift build -c release --product Safarier`、`scripts/test-native-background-input.sh`、`SAFARIER_ARCH=arm64 scripts/build-app.sh`：按 G0 前置条件停止，未执行；不推断通过或失败。纯逻辑测试的无 GUI 安全性也尚未逐项确认。
- 完整 `swift test` 及其他 GUI/原生输入矩阵：当前桌面禁止执行，隔离图形环境未提供，未执行。
- 未启动任何 GUI/App/浏览探针，未访问真实 Profile，未安装 App 或变更全局 Xcode 选择、系统权限和输入状态。
- sing-box 相关测试未运行，无法判断是否有跳过或覆盖情况。

## 主代理复核（2026-10-28）

- 已从新建子会话运行元数据核实执行角色为 `terra-worker`、模型 `gpt-6.1-terra`、推理强度 `high`。该 worker 只做 Task 0 诊断，未承担 review。
- 主代理检查完整诊断日志、最小 manifest 和库导出符号；独立重跑项目 `swift package dump-package` 与最小 manifest 命令，二者均 exit 1、同一个 PackageDescription 未定义符号。确认 G0 不满足，不能把报告写完当作构建通过。独立日志在 `/Volumes/RC500/dev/safarier/.build/automation-main-review/`。
- 主代理基于执行前的 117 个已存在文件哈希检查 worker 写入范围：117 个文件全部未变，唯一新增可见文件为本报告。随后仅由主代理更新设计/计划的用户批准、执行角色、前三项诊断 checkbox 与 blocked 状态，未更改运行代码或既有测试。
- `Package.swift` 及原 AppKit 测试源码检查表明完整测试会创建/激活窗口；本轮不运行。Core/Network 测试未见 AppKit/WebKit 导入或显式 GUI 输入调用，但本轮未执行，也不将源码扫描当作完整无干扰验收。
- 主代理结论：接受 Task 0 的诊断证据，**不放行 G0，不进入 Task 1**。未提交/推送/安装/发布；未改变全局 Xcode 选择、系统权限或用户输入状态。

## 已有 Xcode 扩展定位（2026-10-28）

本次按用户提示扩大只读定位，不改变上述原始诊断或主代理复核。结论是：**在下述限定范围未发现当前可用的完整 Xcode、Xcode `.app` 候选或 `.xip` 归档；G0 仍 blocked。** 这不是整机从未安装过 Xcode 的证明。当前已选择的仍是 CLT，不是完整 Xcode。

证据目录为 `/Volumes/RC500/dev/safarier/.build/automation-xcode-search/`；各诊断命令及 stdout、stderr、退出码分别保存在同名前缀的 `.command`、`.stdout`、`.stderr`、`.exit` 文件。

| 检查 | 退出码 | 结果与证据 |
|---|---:|---|
| `mdfind 'kMDItemCFBundleIdentifier == "com.apple.dt.Xcode"'` | 0 | 未返回路径；`spotlight-bundle` |
| `mdfind 'kMDItemFSName == "Xcode*.app"c'`，另查 `kMDItemDisplayName` | 0 / 0 | 均未返回路径；`spotlight-name`、`spotlight-display` |
| `mdfind 'kMDItemFSName == "Xcode*.xip"c'` | 0 | 未返回路径；`spotlight-archive` |
| `ls -la /Volumes`、`mount` | 0 / 0 | 枚举 `/Volumes/AirSync`、`/Volumes/Macintosh HD`（指向 `/`）、`/Volumes/RC500`；`volumes`、`volumes-mount` |
| `python3 .build/automation-xcode-search/inventory.py` | 0 | 在 `/Applications`、`~/Applications`、`/System/Volumes/Data/Applications`，每卷根及其 `Applications`、`Developer` 中，检查直接匹配 `Xcode*` 的名称；同名子目录限深检查；`~/Downloads` 只检查直接匹配的 `.app`/`.xip`。记录真实路径、缺失目录与扫描范围；无候选；`inventory` |
| `mdutil -s / /Volumes/RC500 /Volumes/AirSync` | 0 | `/` 和 RC500 索引启用，AirSync 索引停用；`spotlight-status`。状态检查未创建或更改索引；Spotlight 空结果不能证明卷内不存在文件 |
| `xcode-select -p` | 0 | `/Library/Developer/CommandLineTools`；`developer-dir` |

没有发现 `.app` 候选，故无候选版本、Info.plist、Developer 组件或许可证状态可报告；也没有可确认的 Developer 路径可用来执行 `DEVELOPER_DIR=... xcrun --find swift`、`xcrun swift --version` 或项目/最小 manifest 重试。没有发现可作为“曾安装过”的旧索引或下载归档线索；不能据此否定用户的历史安装记忆。未运行构建或测试，未打开 GUI，不联网、不安装、不展开归档、不接受许可、不更改 `xcode-select` 或 TCC。

下一步请用户提供已安装 Xcode 的实际 `.app` 或 `Contents/Developer` 路径，或准备包含 SwiftPM、macOS SDK 和 XCTest 的兼容完整 Xcode；主代理复核后再以单命令 `DEVELOPER_DIR` 验证。完整 G0 还需隔离图形会话执行完整测试。

### 扩展定位的主代理复核

- 已审阅 worker 的定位脚本、实际检查范围、Spotlight/目录枚举与索引状态日志；独立按 Xcode bundle ID 重查 Spotlight，exit 0、没有返回路径。空结果只支持限定范围内未找到，不作整机不存在的结论，尤其 AirSync 索引停用。
- 原有 117 个受保护文件内容未变，本报告原内容保持原样，仅追加定位结果。系统全局 Developer 选择保持 `/Library/Developer/CommandLineTools`，未运行 GUI/build/test 或执行安装。
- 维持 G0 blocked；需要进一步的位置线索或现成完整 Xcode 路径。不能凭“应该装过”构造路径并跳过验证。

## 工具链要求澄清与后续进展（2026-10-28）

此前提出完整 Xcode 是获取配套工具链的一条建议，不是唯一技术条件。用户随后批准先调查“不安装完整 Xcode”的路线，结果见 `/Volumes/RC500/dev/safarier/docs/verification/2026-10-28-automation-clt-alternative.md`。terra-worker 和主代理已分别用本机命令级诊断 overlay、全新缓存解析原 manifest 并编译/链接正式 Safarier 产品；默认 SwiftPM 本身仍报错，原 XCTest 缺失且未运行任何原测试或 GUI，所以维持 G0 blocked，不用本次 debug 编译替代完整验收。以上追加不改写本报告早期已执行命令的历史结果。
