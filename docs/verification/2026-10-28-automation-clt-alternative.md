# 2026-10-28 G0：CLT 命令级替代路线调查

## 结论

在当前机器和当前 checkout 上，**未安装完整 Xcode、未修改系统工具链**，通过一个仅用于诊断的命令级 VFS overlay、独立 module cache 和 manifest 编译器包装脚本，成功解析原 `Package.swift` 并以 SwiftPM **编译、链接**原 `Safarier` 产品。输出日志明确包含正式入口 `main.swift`。没有启动或运行产物；这不等于可发布的 App、运行功能正常或标准未经调整的 SwiftPM 通过。

XCTest 是独立阻塞：当前 CLT 上最小 `import XCTest` typecheck 失败，检查的 CLT/SDK/system 明确路径中未找到 XCTest。**G0 仍 blocked**：本轮没有运行原测试，完整测试还需隔离图形会话；此临时 interface overlay 的受支持性和可重复性须由主代理判定。无需完整 Xcode 已验证的是上述本机编译能力，不是 XCTest 全测方案。

证据目录：`/Volumes/RC500/dev/safarier/.build/automation-clt-alternative/`。以下每个前缀均有 `.command`、`.stdout`、`.stderr`、`.exit`；构建输出、实验文件、overlay 与本地缓存均在该目录。`run.sh` 忠实保存参数、stdout、stderr 和退出码。调查前 118 个已跟踪及未跟踪可见文件的 SHA-256 在 `before-hashes.stdout`，后验 `hashes-recheck` exit 0、全部一致；本报告在检查之后新建。工具链接口和 `Package.swift` 的前后哈希也一致（`interface-hashes`、`interface-hashes-after`）。

## 现状与调用路径

- 原报告、贡献规范、设计和 `scripts/background-input-probe/build-native.sh`、`build-probe.sh` 已读取。原 probe 脚本固定输出旧目录且以 `ProbeMain.swift` 替代正式入口，因此未执行或冒充正式构建。实际构建改用 SwiftPM 产品目标，复用现有源码和依赖图，没有新建执行器或浏览器。
- `versions`、`developer` exit 0：Apple Swift 6.3.3，选中 `/Library/Developer/CommandLineTools`。`manifest-fresh` exit 1，原 manifest 链接缺 `PackageDescription.Package` 初始化符号（`swiftLanguageVersions: [SwiftVersion]?`）。
- `interface-facts`、`interface-hashes`、`symbols` exit 0：同一个本机 `ManifestAPI/PackageDescription.swiftmodule` 的 arm64 **private interface** 标记 Swift 5.10，声明独立的 `SwiftVersion`；**public interface** 标记 Swift 6.3.3，将 `SwiftVersion` 定义为 `SwiftLanguageMode` 别名。动态库导出对应 `SwiftLanguageMode` 签名，而原失败请求独立 `SwiftVersion` 签名。完整符号以 `symbols.stdout` 为准。关键 SHA-256：private `2b68a08f707486b49ac091a90881a903291720e37caf9b2321fa6cfad143da66`；public `b87d20a66edfd5a1b96e85d5bf41338bd22c3398188fd1b3473962c84e27eef5`；dylib `e5d8b9723bb02bcdff20b7be7220ac37a0c408c8199022c748b53d9362c9d5b0`；原 manifest `060119776a8031c00cac1a3ad35e752dc51a1541f52f6ed62c88bc56bc988a6c`。
- 本机 `swiftc-help-hidden` 显示 `-vfsoverlay`、`-module-cache-path`；`swift-package-help` 输出显示 `--manifest-cache`、`--scratch-path`、`--cache-path`。后者整体 exit 1，因为打印帮助后仍尝试加载失败的项目 manifest，不能把整体命令称为成功。`dump-help` exit 0，但仅显示子命令简短帮助。工具 help 中有这些选项，并不证明以下混用 interface 和包装编译器的方案是受支持的生产配置。

## 三项有依据的诊断假设

1. **SwiftPM manifest 缓存导致旧结果**：`swift package --manifest-cache none --scratch-path <本目录>/scratch --cache-path <本目录>/cache dump-package`（`no-manifest-cache`）exit 1，仍为相同缺符号。禁用 manifest 缓存不足以修复。
2. **编译模块缓存残留导致旧 ABI**：在上一命令上仅追加 `SWIFTPM_MODULECACHE_OVERRIDE=<本目录>/module-cache`（`isolated-module-cache`）exit 1，仍为相同缺符号。单独换成新模块缓存不足以修复。最小 5.10 和 6.0 manifests 均 exit 1（`minimal5`、`minimal6`）；改 tools version 不是修复，也未改原 `Package.swift`。
3. **private interface 与本机 public interface/dylib 不一致**：仅供诊断，`overlay.json` 将读取 arm64 private interface 的路径映射到同一安装中的 public interface，未改接口文本或库符号；`manifest-swiftc-wrapper.sh` 经命令级 `SWIFT_EXEC_MANIFEST` 给编译器追加 `-vfsoverlay`。该包装器/接口替换是临时诊断办法，不等同官方支持的配置。首次复用假设 2 的已使用 module cache 仍 exit 1（`overlay-manifest`、`overlay-minimal5`）；使用独立的新 module cache 后，原 manifest `overlay-fresh-cache` exit 0，最小 5.10 / 6.0 `overlay-fresh-minimal5` / `overlay-fresh-minimal6` 均 exit 0。结果支持 interface 不匹配与缓存隔离有关；仅凭这些试验不将首次失败的内部缓存命中机制断言为已证明。

`manifest-compare` exit 0：对原 manifest 成功输出的 JSON 核对了包名、macOS 14 平台、外部包依赖、4 个产品及 9 个目标的类型和依赖图，均与原 manifest 对应，包括 4 个测试目标；未删除或替换测试。该比较并非对所有 SwiftPM 隐含构建设置的等价性证明。

## 正式产品编译与 XCTest

`app-build` exit 0：使用相同命令级 overlay，执行 `swift build --manifest-cache none --scratch-path <本目录>/scratch --cache-path <本目录>/cache --disable-dependency-cache --product Safarier -Xswiftc -module-cache-path -Xswiftc <本目录>/swift-cache`，并在该命令的环境中设置 `SWIFTPM_MODULECACHE_OVERRIDE`、`SWIFT_EXEC_MANIFEST`、`CLANG_MODULE_CACHE_PATH` 到本目录。完整实参见 `app-build.command`。日志包括 `[62/65] Compiling Safarier main.swift`、`Linking Safarier` 和 build complete；未运行生成的可执行文件。产物是本目录 `scratch/arm64-apple-macosx/debug/Safarier`，`file` 显示 arm64 Mach-O，SHA-256 `7f6246a4f22218e3b007044596cdf35f00ff862b4931283f387b4b66d784f90a`（`build-binary-info`、`build-binary-hash`，均 exit 0）。这不是 `scripts/build-app.sh` 产出的签名 App bundle，也没有进行 release 构建。

`xctest-typecheck` exit 1：`xcrun swiftc -typecheck -module-cache-path <本目录>/module-cache <本目录>/XCTestProbe.swift` 返回 `no such module 'XCTest'`。`xctest-paths` exit 0：检查的 CLT Developer Frameworks、CLT macOS SDK、CLT Swift macOS 库和系统 Frameworks 路径均未发现 XCTest。没有伪造或删除 XCTest，也没有用禁用 XCTest、Swift Testing 或零测试成功来冒充原测试通过。

## 未执行及最小后续依赖

- 未执行任何测试、产物、GUI、浏览器、输入探针、AppleScript 或安装，未修改系统 SDK/CLT、全局配置/TCC、原源码、脚本、设计计划和 G0 报告；未清除全局缓存。无真实 Profile 访问。
- 若要恢复原 XCTest 测试，需要可用于此项目和本机工具链的真实 XCTest 模块/框架及其编译链接环境；本次只证实当前环境缺失，**没有验证独立于完整 Xcode 的 XCTest 供应或兼容方式**。如方案需要安装或下载任何组件，须先由用户明确批准，不能由本报告推断授权。
- 验证完整 G0 还需主代理评估 interface overlay 的可信性和支持边界、选择可重复且兼容的构建环境，并在隔离图形会话执行需要窗口的完整测试。用户日常桌面上不运行该完整测试。计划 checkbox 未更改。

## 主代理独立复核（2026-10-28）

- 已审阅 compiler wrapper、单文件 VFS overlay、实际命令、manifest 目标核对器与编译日志。overlay 仅让当前命令从本机已有 public interface 读取 PackageDescription；没有改写接口文本、伪造符号/框架、替换 main.swift 或删测试目标。暂只接受为本机诊断证据，不宣称是受支持的正式修复。
- 在 `/Volumes/RC500/dev/safarier/.build/automation-main-review/clt-repeat/` 复制诊断脚本并使用全新的 manifest/Swift/Clang 缓存，独立重跑原 manifest exit 0，输出 JSON 与 worker 完全一致；用 `--jobs 2` 编译/链接正式产品 exit 0，日志包含 Compiling Safarier main.swift、Linking Safarier；未执行二进制。该次产物 SHA-256 为 `06cede9eb99ba3bb4a9b308a8f92bfcf90906252d822445bf7487bbd5ea0ebb7`，哈希只标识本次产物，不要求不同绝对路径的 debug 构建逐字一致。
- 主代理独立最小 import XCTest typecheck exit 1、no such module；默认无 overlay 的 dump-package 再次 exit 1，证明未修复/更改全局工具链。没有运行 swift test；不能把测试未被发现/被跳过当作绿测。
- worker 返回时原有 118 个可见文件和 5 个已安装 PackageDescription 文件哈希全部未变，唯一新增可见文件为本报告；随后主代理仅同步设计/计划和旧报告的状态澄清。系统 Developer 选择不变，未安装/下载、启动 GUI、使用全局输入或访问真实 Profile。
- 官方边界核对：SwiftPM 的 PR #7805 明确讨论 CLT 不带 XCTest 和缺失时跳过 XCTest；本仓库四个原测试目标均使用 XCTest（静态盘点，不是执行），所以不能以跳过换通过。来源：`https://github.com/swiftlang/swift-package-manager/pull/7805`。Apple 的 CLT 文档支持无需完整 IDE 的命令行开发，但不保证本机这套不一致安装已恢复。来源：`https://developer.apple.com/documentation/xcode/installing-the-command-line-tools`。
- 结论：已证明无需安装完整 Xcode 可进行本机正式入口的命令行编译；**没有放行 G0，也没有开始后台控制功能编码或完成可用 App 交付**。剩余真实测试组件与隔离图形验收按原安全约束解决。
