# Legacy 系统拖拽入口拒绝：候选实现与重复验证

日期：2026-10-30（Asia/Shanghai）。仓库 `/Volumes/RC500/dev/safarier`，分支 `mcc-safarier`，HEAD `2f32d21248deaffd8c8c1152a39912aa46350c7e`。用户要求继续已批准的无全局输入后台方案；Terra 实现，主 agent 唯一 code review 并独立运行验证。以 283 个已有文件为基线，不恢复 VM。

## 结论

**已把上一轮证实的 legacy `dragImage:at:offset:event:pasteboard:source:slideBack:` 入口接入自有 WebView 的拒绝边界，而不再仅靠诊断进程退出。** 真实 WebKit 请求在三轮启用负例中均被本类边界拒绝，原生 driver 同步静止；未触发外层入口 tripwire，也没有继续投递 up/drop。禁用拒绝的对照仍触发外层 tripwire，证明验证能区分拒绝与放行。

**这是 legacy 局部候选修复，不是完整后台拖拽支持或不干扰验收通过。** 现代 nonnull session 入口未获得安全取消实现，Factory/Native/defaultscript 门禁不变；正式 Factory→OwnedPage→AppleScript 闭环未执行。原 25 项并未全部完成，启用负例按预期 `allPassed=false`，不能写成 25/25 通过。

## 1. 复用现有源码与 owner，不加另一套输入器

五个生产文件的限定改动：

1. `/Volumes/RC500/dev/safarier/Sources/SafarierObjCSupport/SFRRuntime.m` 与 `/Volumes/RC500/dev/safarier/Sources/SafarierObjCSupport/include/SafarierObjCSupport.h`：增加固定 `SFRInstallLegacySystemDragBoundary`，仅向一个 WKWebView 子类添加固定 legacy 方法。完整核对 void 返回、自身/selector 与七个显式参数 ABI，以及固定 `canBeginLegacySystemDrag` 的 BOOL/无额外参数签名；已有 own legacy 实现时拒绝覆盖。幂等安装核对 owner/permission/继承原 IMP。入口 off-main 或实现漂移时拒绝；permission=false 直接 void 返回，true 才以 typed 原 IMP 转发全部原参数。没有改 NSView/NSWindow 的实现、无广义 selector API、无进程退出或全局输入。
2. `/Volumes/RC500/dev/safarier/Sources/Safarier/Browser/BrowserViews.swift`：本类提供固定 `@objc` 许可方法；未绑定实例保留人工行为。安装状态字段只记录初始化时结果，运行时桥另核对 ownership；不是持续安全能力证明。
3. `/Volumes/RC500/dev/safarier/Sources/Safarier/Browser/BrowserWindowController.swift`：展示前把许可绑定到既有 `session.allowUI(.systemDrag)`，weak owner 丢失时拒绝。活着的 interactive session 沿原策略许可，automationBackground 使用已有 `cancelAndSuspend` 通知，不另写策略。
4. `/Volumes/RC500/dev/safarier/Sources/Safarier/Automation/OwnedBrowserAutomationPage.swift`：原 `block` 在 invalidated/epoch/correlation 失效后、通知 controller 前调用原 `input.closeActivity()`，同步停止后续 native 送入；销毁/错误回执/owned Runner 收尾仍由原 owner 路径负责，不伪造 destruction receipt。

根目录的 NativePageInput、NativeEvents、原 fixture、事件顺序、坐标、hover/按住执行逻辑均未改。导航重开 input 不会移除 view 的 session 绑定；其正式运行链仍待验收。没有补 mouseUp/click/drop，也没有把“关闭本地查询”当成已撤销既有网页业务副作用。

## 2. SDK 约束与 RED/GREEN

本机 Xcode SDK 将 legacy 方法标为 Swift unavailable，初次直接 override/super 编译失败。失败源码与日志留在证据目录；没有删检查换绿。按原 Task 2 已允许的必要固定 ObjC bridge 扩展，改用上述本类 `class_addMethod`；不是全进程 swizzle，也不是绕过现代 nonnull 返回约束。

新增 XCTest 的初始 RED、不可编译 override、仅 helper 的 partial GREEN，以及 bridge 缺失的 RED 均保留。最终四项新增 XCTest 覆盖原人工许可、每次一次 policy、后台 systemDrag 拒绝、隐藏控制器真实安装/绑定与 weak owner 失效、原门禁关闭。人工转发不通过真实 OS drag 验证，而用 typed spy，避免为了测试制造全局拖拽。

原 `/Volumes/RC500/dev/safarier/Tests/NativeInput/ScopedMouseStateTests.m` 扩充到 **58 checks**：逐项错误 ABI、permission 返回/参数数目不符、已有 own 方法、主线程限定、重复/第二目标拒绝、拒绝不调用 original、人工许可仅转发一次、selector/所有对象/非零 point/size/BOOL 精确保真、ownership/permission 漂移、NSView 未改与 NSApp=nil；原 scoped 按钮/异常/并发/光标/query-origin 检查保留。

主 agent 复核时发现新 fixture 硬编码 ARM 的 BOOL encoding，要求 Terra 仅将合法签名改为 `@encode(BOOL)`，坏返回和额外参数负例保留。五个生产文件与新增 XCTest 哈希未因此改变。最终版本主 agent native suite 三轮（main-native-2/3/4）每轮 58 checks 通过；之前 main-native-1 留档，不混淆修正前后。ObjC 桥 x86_64 仅编译通过，未运行 x86_64、Rosetta 或 VM，不等于 universal App 验收。

## 3. 真实 native 负例与对照

私有 probe 从上一轮 trap probe 仅增加诊断 policy 注入与否决报告，逆变换 byte-equal。主 agent review、编译链接当前生产 Swift 源与新 ObjC 桥、独立签名验证通过。它保留原 25 个 case/`allPassed`、原 fixture 与 NativeEvents；不覆盖原探针源码。

- pre-App 安装外层固定公开拖拽入口 tripwire；它只用于本次诊断，防止对照真正进入 OS 拖拽，安装日志 NSApp=nil。
- `disabled` 保留真实 interactive session 绑定，legacy 许可沿原 IMP；外层 tripwire 退出 71。
- `enabled` **仅在私有 probe** 注入现有 BackgroundPagePolicy(.automationBackground)，否决时使用原 driver.closeActivity()，不补发事件。主 agent review 删除了重复 window.close。即刻记录 activityReady/activityClosed/status/driver trace，异步安排原 finish；即刻读回不是异步 finish ack。
- 参数缺失/重复/未知值不会静默启用；主 agent 实际二进制三种非法参数均退出 64，未创建输出或 NSApplication。

| 场景 | 自有进程退出 | 原系统方法 tripwire | policy 否决 | 原功能检查完成 | 原 allPassed |
| --- | ---: | --- | --- | ---: | --- |
| disabled 对照 | 71 | 命中，栈含本类 bridge 与 WebKit startDrag | 无 | 15 | 没有最终报告 |
| enabled-1 | 0 | 未命中 | systemDrag | 15 | false |
| enabled-2 | 0 | 未命中 | systemDrag | 15 | false |
| enabled-3 | 0 | 未命中 | systemDrag | 15 | false |

三轮 enabled 均发生在 held_state_is_process_local 后，held mask=1、own inactive、window 非 key；`closeActivity` 后 ready=false/status=OK，而 closed 即刻仍可能 false，**未冒称完成异步 ack**。最终 driver trace 与否决后快照逐项完全相同，均以 activityEndStatus 结束，没有否决后的 up/drop 或其它 native 事件；原报告 error 明确为 `legacy system drag blocked`。自身激活观测为 false、own global pointer events=0。

每轮外部 observer 12 秒/1200 样本，始终 NSApp=nil，覆盖否决时刻；四份真实报告 schema 检查均通过。此次各轮均有外部活动计数变化，不能当成静默输入实验：enabled-1 全程仅基线 cursor，enabled-2/3 出现多种 cursor 图像，前台采样 PID 均稳定。保留这些读数，不将所有变化强行归因外部，也不靠原 oracle 的“有外部输入就允许 cursor 变化”声称 G5 通过。验证支持的是本类 legacy 入口拒绝与停止继续送入，不是全系统零干扰证明。

精确证据：`/Volumes/RC500/dev/safarier/.build/automation-system-drag-guard-20261030/native-negative-summary.json`。各轮 trace/外部 observer 仍按其固定私有父目录写到上一轮证据目录；本轮 status/summary 逐项给出绝对位置，没有覆盖旧报告。否决文件 0600、输出目录 0700。

## 4. 原完整 XCTest 三轮

使用新的自有 canonical 短路径 fixture，原 helper 与固定 sing-box 测试依赖全部显式配置，原 swift test 不 filter/不删检查，2 jobs/no-parallel，主 agent 独立执行三轮：

| 目标 | 每轮 entries | 原条件 skip | failure |
| --- | ---: | ---: | ---: |
| SafarierWebKitTests | 77 | 2 | 0 |
| SafarierNetworkTests | 100 | 0 | 0 |
| SafarierCoreTests | 96 | 0 | 0 |
| SafarierAppTests | 70 | 1 | 0 |
| 合计 | **343** | **3** | **0** |

每轮实际 340 pass/3 skip；不是 Swift Testing 的 0 tests 文案。三个 skip 为原 OS/SPI 条件与 ManagerLifecycle 的明确 GUI 验收占位，不自动填成通过。新增四项 XCTest 在每轮真实执行。证据：`/Volumes/RC500/dev/safarier/.build/automation-system-drag-guard-20261030/full-xctest-summary.json` 及 full-1/2/3 日志/退出码。

## 5. 保留的门禁与下一步

- **现代入口仍未封堵**。不能对 nonnull NSDraggingSession 返回 nil/fake，也不能把本次 legacy void 返回推广过去；不得宣称 systemDrag safety capability 完整。
- Factory 背景配置、NativeInputPreflight/NativePageInput shipping admission、默认脚本入口保持关闭。后台 Factory 目前拒绝构造，因此本轮使用私有 policy 注入的 native 结果不是正式 OwnedPage/Runner/AppleScript 端到端证据。
- OwnedPage 的同步静止已在原路径接线，但正式 session 的 blocked 回执、异步 finish ack、销毁证明、owned Runner 退出预算还需真实闭环验证；不能只因源码 closeActivity 调用存在就视为完成。
- 原完整 25 项与隐藏/遮挡/退出矩阵未通过，本轮明确提前拒绝了原 fixture 的系统拖拽请求。必须继续处理现代源入口与允许的纯页面拖动边界，再完整重跑，不删掉原 held/release/scroll 检查。
- 真实并行文字接收、修饰键、输入法验收仍未覆盖；不向用户前台 App 合成全局按键制造数据，不恢复全局 cursor/焦点/输入源。

本轮未安装/发布正常 App、未提交/推送，没有 VM、全局输入 fallback、网页脚本/DOM 事件注入或用户 Profile/凭据使用。所有本轮自有诊断进程正常或按预期退出并 wait 回收；不按进程名清理他人窗口。仅五个生产文件、一个原 native 测试和原计划限定修改，新增一份 XCTest 与本报告，其它 baseline/兄弟仓库/缺失资源/工具路径按最终 hash 审计保全。详见 `/Volumes/RC500/dev/safarier/.build/automation-system-drag-guard-20261030/final-review.json`。
