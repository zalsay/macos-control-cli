# 本机完整 XCTest、原 App 打包与后台输入诊断：构建链通过，光标异常仍阻断放行

日期：2026-10-30（Asia/Shanghai）。分支 `mcc-safarier`，HEAD `2f32d21248deaffd8c8c1152a39912aa46350c7e`。

**结论：原完整 XCTest 已连续三轮每轮 339 项、336 passed / 3 skipped / 0 failed，原 App 打包与 ad-hoc 签名通过；但后台页面首轮诊断的“不干扰”检查出现单帧光标 TIFF 哈希变化，尚未归因。一次只读外部观测的复跑未重现，不能据此抹掉首轮失败。正式后台输入门禁继续关闭，不交付“已保证不干扰”的结论。**

证据根目录：`/Volumes/RC500/dev/safarier/.build/automation-full-xctest-20261030/`。

## 1. 本次授权与边界

用户明确确认允许本轮本机测试窗口出现或短暂激活；不恢复虚拟机，不把这个专用时间段冒称隔离桌面，也不以 `--isolated-ui` 虚假确认环境。原 AppKit 测试实际显示过自有窗口，不能把该时段描述成“不抢焦点测试全通过”。背景输入诊断另行记录自己的激活/全局事件观测。

工作区、fixture、构建、App 输出均使用本次私有路径。不接管真实用户 Profile、不使用真实凭据、不发送全局鼠标键盘或 System Events、不移动/恢复光标或恢复焦点。用于诊断页面状态的 JavaScript 只读取自有 fixture，不是生产网页 DOM 输入兜底。

## 2. 完整 XCTest 的真实结果及失败历史

原 suite 未 filter、未删除测试换绿，显式配置 Controlled/OwnedRunner/OwnedChild/OwnedSingbox helpers 和私有 artifact/service 根，`swift test --jobs 2 --no-parallel` 实际执行所有四个 XCTest target。

| 最终每轮 | test entries | passed | skipped | failed |
| --- | ---: | ---: | ---: | ---: |
| SafarierWebKitTests | 77 | 75 | 2 | 0 |
| SafarierNetworkTests | 100 | 100 | 0 | 0 |
| SafarierCoreTests | 96 | 96 | 0 | 0 |
| SafarierAppTests | 66 | 65 | 1 | 0 |
| 合计，每轮重复三次 | 339 | 336 | 3 | 0 |

最终日志为 `full-accepted-1.log`、`full-accepted-2.log`、`full-accepted-3.log`，退出码均 0；结构化计数见 `full-xctest-summary.json`。Swift Testing 的四条“0 tests”不当作 XCTest 结果；当前 SwiftPM 只生成空 Swift Testing XML，XCTest 计数取实际 case 与 suite 日志双重核对，不用空 XML 冒充全量测试。

三个原条件性 skip 保留并公开：本机无 PingFang 下载资产；字体引擎桥接的已验证 WebKit 条件不匹配；ManagerLifecycle 明确要求独立真实应用事件顺序验收。最后一项不是本轮已完成的正式生命周期证明。

保留的失败与修正：

1. `full-initial.log` 实际 337 entries / 6 skips / 3 failing cases（10 条 assertion failure）。两个 snapshot/service failure 是主 agent 的 fixture 使用 `/tmp` 符号链接，被原逐级 NOFOLLOW 检查正确拒绝。仅把本次已创建夹具改用 `/private/tmp` 的真实路径，生产 SnapshotStore 不放宽；`canonical-snapshot-targeted.log` 两个真实定向 XCTest 通过。
2. FontAllowlistPlanner 原本明确“无需排除字体时 no-op，不设置白名单”，宿主无下载字体资产时原 host test 错把空计划当丢字体。Terra 仅修改 `/Volumes/RC500/dev/safarier/Tests/SafarierWebKitTests/FontAllowlistPlannerTests.swift`，验证完整 no-op 语义，并在有排除字体时保留原 8 项名字断言；新增确定性 matching-asset no-op fixture。生产 planner 没改，也没有新增 skip。
3. 一次复跑 338 项通过后，下一轮捕获真实 `.invalid` DNS 失败等待超时，记录于 `full-final-2.log`。初次“只 bind 不 listen”的夹具在本机得到 ETIMEDOUT 而非预期拒绝，失败尝试被撤回并留档，没有改 expected 掩盖。最终只修改 `/Volumes/RC500/dev/safarier/Tests/SafarierAppTests/BrowserFixesTests.swift`，由自有 127.0.0.1 随机监听端口对 accepted 连接发送真实 TCP reset，保留所有原 WebKit 导航/错误页/后退断言，新增重复 reset 与 CLOEXEC 检查；单一 cancel-handler 关闭自有监听 FD。三轮定向验证及最后 CLOEXEC RED/GREEN 均保留。

以上测试修复由 Terra 实现，所有设计判断、code review 和独立全量复核由主 agent 执行，没有 reviewer 子代理。完整日志未覆盖或改写首次失败。

## 3. 原 vendor 和 App 打包链

当前本机 Go 1.25.6。以原脚本固定 sing-box v1.14.4、`with_utls`、CGO_ENABLED=0 构建 arm64/amd64，源 commit `c005f35300ce76427dc285481ec5695f5b179cd2`；构建后源码 Git 状态仍 clean。Git 初次 HTTP2 fetch 失败保留，单次改为仅该命令 HTTP/1.1 后成功；未禁用 TLS 或修改全局代理/Git 凭据配置。

真正执行原脚本时发现 macOS Bash 3 将紧邻全角标点的 `$arch`/`$VERSION` 误读为变量名。Terra 在 `/Volumes/RC500/dev/safarier/scripts/build-singbox.sh` 仅加四处变量边界，主 agent 比对除这四处外原字节相同，版本/flags/源/许可证协议不变。新增 `/Volumes/RC500/dev/safarier/scripts/automation-core-tests/test-build-singbox-shell.py`，离线完整 mirror/stub 两个方法三轮通过。失败 `vendor-build-http1.log` 和修正成功 `vendor-build-fixed.log` 均保存。

构建只在私有根执行原脚本的字节副本，缓存不安装进系统。真实编译得到 Universal helper 和 LICENSE/COPYING/SOURCE；之后以新 helper 跑完整 XCTest，原三个“缺 sing-box”skip 变成真实测试通过，测试只用本次状态目录、文档示例节点和自有 loopback，不接真实订阅代理。

原生产 Sources/Package/打包脚本按 hash 复制到私有 package-root；先以两 jobs 预编译 Universal Release，再执行未经修改的原 `build-app.sh`，本机 arm64 App 输出：

`/Volumes/RC500/dev/safarier/.build/automation-full-xctest-20261030/packages/Safarier.app`

Bundle ID `sh.safarier.app`，版本 1.0.1 build 2。App 和自带 helper 均 arm64，主 agent 独立 `codesign --verify --deep --strict` exit 0，许可证资源完整。见 `app-package-verification.json` 和 `original-app-package.log`。这是本机 ad-hoc 构建，不是 notarization、安装或发布；没有启动该正常 App。默认脚本 metadata 仍关闭，不能将这个包描述成已可用的 AppleScript 自动化产品。

## 4. 真页面诊断：功能通过不等于安全通过

复用原 BackgroundInputProbe、真实 BrowserWebView/BrowserWindowController 与本进程 native 路径，以独立 signed bundle 和 ephemeral DataStore 加载原自有本地 HTML。原源码不含全局 CGEvent 投递；page fixture 没有外部 URL、picker 或权限请求。nil proxy 路径不会调用已构造 credential store 的读取方法。

没有用旧 LaunchServices/PID 名称扫描清理；主 agent 直接持有新建子进程并设置超时，仅允许对自己的进程组请求退出。这是诊断执行方式，不是正式 Manager/Runner G1/G3 已验收。

- 无输入 stub/hidden 阴性对照：ready_background 通过、click 等输入效果按预期失败，allPassed=false。证明没有因方法被调用就误判功能成功。
- 原 fixed/background 首轮：25 项中 24 项功能/收尾检查通过，包括 hover、hover exit、真实单/双击、checkbox、Unicode/退格、密码不改变全局 Secure Input、range/text/custom-pointer drag、进程局部 held 状态及归零、scroll、trusted native mouse events、活动/临时查询恢复与 cursor guard 安装。
- 唯一失败为 `no_global_input_or_activation`。208 个样本中 1 个 raw cursor TIFF hash 变化，初末 hash 相同；cursor 坐标没变、frontPID 没变、自身激活 false、自身全局 pointer event 为 0、外部键盘/鼠标/修饰键计数均为 0。该单帧原始 TIFF 没保存，所以不能仅凭 hash 宣称实际可见光标改变，也不能宣称它是无害 metadata 差异。

原始 `native-runs/background-1/report.json` 及 CLI 日志保留。程序退出 0 不等于 report.allPassed；主 agent 按 report 断言失败后停止了后续 background/occluded/hidden 正向三轮矩阵，没有产出新的“9×25 全通过”结论。

## 5. 只读外部对照与剩余不确定性

Terra 仅在证据目录 `cursor-observer/` 中实现不创建 NSApplication/窗口、不安装 tap、不写 cursor 的独立只读观察器。公开 NSCursor getter 的 TIFF 可包含多个 image representation；本次读取确实有四个不同分辨率表示，因此 raw 编码变化本身仍需像素证据归因，不能直接拿后续一次稳定覆盖原失败。

同时制作了仅增加 raw TIFF 保存与元数据的 probe 副本，主 agent 逐字节还原检查确认原 25 条判断、raw hash 与 allPassed 逻辑完全不变；没有改仓库原 probe 或 runtime guard。图像为 cursor icon，不是桌面截图；只保存本次输出、0600、最多 16 个不同 hash。representations 从已取得的 TIFF 解码，不枚举原图懒缓存。

一次受控外部对照：instrumented probe 原 25 项通过；独立进程以 10ms 间隔采集 1200 个样本，NSApp 始终 nil、无窗口、frontPID 不变，完整覆盖该次 probe 起止，只观察到同一 cursor hash。保存的内部/外部 TIFF 字节 hash 一致。这个结果只说明那次没有重现，不能解释首次单帧异常；主 agent 没改判据让它变绿，也没有移动/恢复光标。结构化结论：`native-safety-attribution.json`，safetyGate 仍 blocked。

官方读取接口参考（只作 API 语义参考，不代替本地测量）：`https://developer.apple.com/documentation/appkit/nscursor/currentsystem`、`https://developer.apple.com/documentation/appkit/nsimage/tiffrepresentation`。

## 6. 当前门禁、保全及下一步

原完整测试执行和 App 打包签名已取得通过证据，但三个 skip 的未覆盖范围仍在，`xcodebuild -checkFirstLaunchStatus` 本轮最终仍 exit 69，不声明完整 Xcode 初始化完成。正式接收者归属、冷启动事件顺序、UI 逃逸拦截、多状态三轮不干扰、持续人工鼠标/键盘与真实中文 IME 均未全部验收；外部输入计数为 0 不当作“用户一直打字不丢键”的证明。

所有 production Native/Factory/Manager/defaultscript 门禁保持原状。暂不开放或安装自动化 App，下一步只应先归因这条 cursor 观测异常，再继续完整矩阵及正式 AppleScript 闭环，不能依赖全局输入或恢复焦点/光标兜底。

以本轮开始 280 个文件为基线，既有文件全部保留；限定修改两个原测试、原 vendor 构建脚本和计划，新增离线 shell 回归与本报告。生产 Sources、Package、原 App 打包脚本、输入执行器及门禁均未改。冻结 250 个代码/测试/脚本文件无后续漂移，兄弟仓库 dirty 状态和原 10 个缺失资源保全；无提交、推送、安装或发布，无 VM。构建、失败原件、诊断目录及私有测试 fixture 留作证据，不擅自递归删除不确定内容。最终审计见 `final-review.json`；其中 preservation/test/build 成功与 native safety blocked 分开记录，不给出混淆性的总体全绿。
