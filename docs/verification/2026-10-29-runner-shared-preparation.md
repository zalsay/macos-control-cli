# 第十批：共享 Runner 启动准备与后台早期拒绝

日期：2026-10-29。分支：`mcc-safarier`。基线 HEAD：`2f32d21248deaffd8c8c1152a39912aa46350c7e`。

## 结论与交付边界

完成的是**原有 Runner 配置准备的单一路径重构、后台候选接线和默认拒绝验证**，不是后台实际可用，更不是鼠标/键盘非干扰图形验收。正常人工和 probe 复用该准备方法；本批只编译这些真实路径，不运行它们。后台 shipping 路径仍被独立 Native / Factory / Manager cold-launch 门禁拒绝，默认脚本启用状态未改变。

实现由两名实际 `gpt-6.1-terra / high` worker 执行；全部设计、代码复核和独立反例由主代理完成，没有委派 reviewer。两 worker 最终均冻结。

## 原代码调查与实现

1. 原 `/Volumes/RC500/dev/safarier/Sources/Safarier/RunnerMain.swift` 将 Profile 锁、屏幕模拟、出站、sing-box、Geo/自重启、隐私配置与 AppKit 生命周期串在一起。抽出的 `/Volumes/RC500/dev/safarier/Sources/Safarier/RunnerPreparation.swift` 是人工/probe/后台候选共用的唯一准备流程，原代码块已从 RunnerMain 移除，未复制第二份代理或 Geo 实现。原 startSingbox / resolveFollowProxy / relaunch / 退出清理仍由 RunnerMain 持有。
2. `/Volumes/RC500/dev/safarier/Sources/SafarierCore/RunnerPreparationPlan.swift` 只选择已有引用并校验，不读默认工作区、不创建进程或窗口；App 注入原 workspace.proxies.record / workspace.boundNode。保留先 proxy reader 再 boundNode reader、订阅最终优先的规则；未绑定订阅时，丢失或身份不符的代理明确失败，不变直连。
3. `/Volumes/RC500/dev/safarier/Sources/SafarierWebKit/WebViewConfigurationFactory.swift` 的原 interactive-only 拒绝抽为 requireExecutionPolicy，factory.make 自身仍最早调用。共享 prepare 的第一步也是同一 guard，之后再校验 spec/policy 一致，才允许任何工作区读取、设备 hook、凭据或配置准备。
4. 后台 Runner 在保留原授权/blank/SPI guard 并检查非 probe 后，用已有 validateConnectedStream 检查原 stdin；准备完成前不 adopting，不提前关闭可能要跨 execv 的 fd0。Native 拒绝分支才接管为原 unavailable RPC。较丰富的 Entry overload 位于 App 准备文件，原 Foundation-only `/Volumes/RC500/dev/safarier/Sources/Safarier/Automation/RunnerAutomationService.swift` 字节不变。
5. 未来通过全部门禁的候选成功分支复用原 BrowserSession.makeAutomationService / RunnerAutomationService.serve，不另起服务。RunnerMain.makeAutomationService 自身也先检查 Native admission、prepared policy 和 Profile 许可，之后才可能创建 NSApplication。**该成功分支未执行，AppKit 事件循环与冷启动时序仍需隔离图形验证。**

## 不能直接复用的旧行为：明确拒绝，不作兜底

- 原 SingboxProcessManager.start 包含按旧 PID 文件 reapOrphan 和 quarantine 修改。本批不改人工路径、不新增并行 sing-box owner；后台 subscriptionID 非空直接 BACKEND_UNAVAILABLE，且在 reader 之前拒绝。
- 后台 followProxyLanguages / followProxyTimeZone 暂时 BACKEND_UNAVAILABLE。真实 Geo 探测、跨自重启控制连接、总启动预算尚未验收，不能因推迟 adopting 就宣称已支持。
- 既有 factory 对**任意非 nil username（包括空字符串）**都会访问 CredentialStore。后台 plan 因此统一 INTERACTION_REQUIRED；不读真实 Keychain，不弹窗，不去掉代理转直连。人工用户名行为保留。
- 本批没有全局事件、光标移动、System Events、焦点切换/恢复或 DOM/JS 输入兜底。NativeInputPreflight.shippingAdmissionAvailable 仍 false；Factory 后台仍 UI_POLICY_UNAVAILABLE；Manager coldLaunchVerified 仍 false；旧 ScriptService 与默认脚本设置不变。

## 主代理复核发现与修正

- 恢复并加强后台 start 的原启动授权 guard，不能因下游 unavailable 而删掉原检查。
- 给 makeAutomationService 自身补 admission/policy/许可检查，不能只相信调用方或注释就创建 NSApplication。
- 绑定 spec.backgroundAutomation 与 executionPolicy，防止后台 spec 被当成人工配置准备。
- 独立运行证明空用户名原候选被放行（RED）；追到 factory 的非 nil 判断后，Terra 将后台判定修为 username != nil，补空/空白用户名及正常人工兼容用例。

## 最终冻结验证

证据根目录：`/Volumes/RC500/dev/safarier/.build/automation-stage10-main-review/`。

| 检查 | 当前批结果 | 能证明什么 |
| --- | --- | --- |
| 冻结 Sources/Tests/scripts | 222 文件 | 最终运行期间源码未漂移 |
| 联合协议/IPC/Manager/会话/UI policy/controller/native preflight/截图/新 preparation | 3 轮，每轮 2,276 checks | 包括新增共享 preparation 48 条；纯逻辑、synthetic 和私有 Foundation IPC，不是 GUI |
| 主代理独立 preparation | 20 条 × 3 轮 | 身份、顺序、拒绝、错误和普通路径兼容 |
| 真实 Repository / workspace reader | 10 条 × 3 轮 | 私有 JSON 文件、真实绑定和错误传播；不连网络 |
| 实际产品对象链接的 shared prepare + richer Entry | 28 条 × 3 轮 | 原工厂 gate 先于 poisoned metadata；原始 socket 握手/EOF、Unavailable 回包、NSApplication 始终 nil |
| 既有实际 Factory / Native / 旧 Entry / Model-Hook-shipping | 各 3 轮通过 | Factory 8、旧 Entry 6、Model 12 与 Native 拒绝；无 GUI/AppleEvents |
| 既有主代理独立逻辑与进程用例 | 各 3 轮通过 | Manager11、目录29、scheduler4、真实 Manager-client-child-server8，及 controller/UI/session/policy/script/native/snapshot/service/navigation/owned IPC 等既有反例 |
| 私有 service EOF 清理反复验证 | 20/20 | 同一 1 秒 monotonic 有界条件观察 page 与 storage 均完成；不代表真实 WebView 销毁 |
| 正常 Safarier 产品 / 诊断 probe | 编译链接 exit0，无 warning | 不运行产品或诊断；正常构建无诊断 ctor/trace 符号，诊断构建有 5 个 |
| 源码接线检查 / metadata | 15 / 32 项通过 | 结构与 metadata-only 输出，不是 OS 接收者/冷启动验收 |
| XCTest wrapper | parse 通过；完整 XCTest 未运行 | 当前 CLT 实测 import XCTest 仍 no such module |

最终联合检查构成：protocol340、channel28、wire117、controlled56、script59、launch64、policy117、session354、boundary395、controller319、native60、snapshot69、multiplex35、owned104、service51、artifactBase39、manager21、preparation48。

### 验证期间的失败及处置（未隐去）

- 第一次复用的独立 service fixture 在 page.destroy 计数变为 1 后立即检查目录，出现 `EOF closes own artifact directory` 失败。原产品 Service 与本批基线字节相同；其 storage.close 在独立 task，page 计数不是 storage 完成凭据。fixture 改为在原 1 秒有界轮询内同时观察两项，保留最终断言，未放宽产品代码或清理预算。原失败保存为 `independent-service-round-1-initial-fixture-failure.*`；修正后既有三轮和额外 20 次均通过。
- 新链接 fixture 首次编译把 throwing 目录读取放入非 throwing Bool autoclosure，编译失败；改成先读取再断言。保留 `actual-preparation-compile-initial-fixture-failure.*`。
- 空用户名独立 RED 是候选产品逻辑缺陷，不是上述 fixture 问题；已由 worker A 修正，保留 `empty-username-regression-red.*` 与 worker 的 username-red/green 日志。主代理 fixture 随后改为显式捕获断言错误，避免测试失败产生顶层 Swift trap。

## 构建环境与文件保全

只沿用上一批命令级 manifest VFS overlay 和独立缓存，未修复或更改系统工具链。当前 xcode-select 仍 `/Library/Developer/CommandLineTools`，5 个既有工具链保护文件 hash 不变。不能把此构建结果描述成默认 SwiftPM/XCTest 环境已修复。

240 个基线文件中，237 个不变；限定修改 RunnerMain、WebViewConfigurationFactory 和正式实施计划 3 个文件。新增 7 个代码/测试/脚本文件与本报告，共 8 个；10 个原缺失资源仍保持缺失；相邻 chrome-control-cli checkout 状态未变。未 staging/commit/push/install/release，未改系统权限或 TCC。

## 下一道门槛

先在已有网络/凭据/启动模块内补后台安全的 owned-only 代理生命周期、无交互凭据读取和有界 Geo/重启流程，再验证 AppKit 后台宿主事件循环。之后才能开展隔离环境下的真实悬停、按住、拖拽、键盘、53 项系统 UI、冷启动多实例投递及鼠标键盘非干扰验收。G0/G1/G2 未通过前不开放 shipping，不能把本批候选接线当成已能实际控制页面。
