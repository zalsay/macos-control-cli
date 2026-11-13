# 现代拖拽拒绝与断链先停输入：候选实现验证

日期：2026-10-30（Asia/Shanghai）。仓库 `/Volumes/RC500/dev/safarier`，分支 `mcc-safarier`，HEAD `2f32d21248deaffd8c8c1152a39912aa46350c7e`。以285个已有文件为基线，继续原Task2/5/8；Terra worker 实现、主agent唯一code review及独立验证。无VM、全局输入fallback或正常App发布。

## 1. 结论与纠正

**现代 event 型系统拖拽入口已加入现有自有类边界，并在本机ObjC组件负例中连续三轮拒绝成功。** 返回值nil只在ObjC层处理，传给Swift的是BOOL；不创建假NSDraggingSession，不调用原系统方法，也不靠产品进程_exit。

需要纠正前两批“nonnull意味着ObjC不能返回nil”的过强推断：Apple官方event API文档同时给出Swift非可选签名和以下Return Value说明：

> The dragging session for the drag, , or nil if the method can’t start the session.

本批据此在ObjC中表达“策略拒绝、会话无法启动”，没有把nil冒充有效session；不对任意Swift非可选调用方作保证。Apple gesture API也明确允许启动失败nil，但本机实际没有该selector，未运行其GUI负例。官方原JSON与URL/hash清单位于：

- `/Volumes/RC500/dev/safarier/.build/automation-quiescent-shutdown-20261030/modern-api/event.json`
- `/Volumes/RC500/dev/safarier/.build/automation-quiescent-shutdown-20261030/modern-api/gesture.json`
- `/Volumes/RC500/dev/safarier/.build/automation-quiescent-shutdown-20261030/modern-api/manifest.json`

**并未完成原25项或G1–G5。** 此次负例仍在第15个功能检查后拒绝，原allPassed=false；modern event是固定ObjC组件调用，不冒充本机WebKit已经采用该入口。当前WebKit实际legacy路径额外回归一次。Factory/Native/defaultscript门禁均未开放。

## 2. 现有边界扩展，无平行输入架构

仅扩展 `/Volumes/RC500/dev/safarier/Sources/SafarierObjCSupport/SFRRuntime.m` 及原头文件，沿用历史安装API、单一目标类和既有session permission，不新增平行hook/owner。固定三个selector：

- `dragImage:at:offset:event:pasteboard:source:slideBack:`：void/9个总参数。
- `beginDraggingSessionWithItems:event:source:`：对象返回/5个总参数，必需。
- `beginDraggingSessionWithItems:gesture:source:`：对象返回/5个总参数，仅父类runtime存在时安装。

全部现存入口的完整ABI、own方法冲突和permission签名先预检，再仅对BrowserWebView子类class_addMethod；不改NSView/NSWindow。幂等安装及使用时核对整个固定集合、permission与继承原IMP，漂移/非主线程/不完整安装拒绝。后台false时legacy直接返回，modern返回nil；人工true时原参数与原返回值精确保真。缺失可选gesture不会伪造方法可用；能力完整性与shipping仍保持false。

主agent复核发现并要求修复一次实际selector错误：worker起初用了`gestureRecognizer:`，与SDK公开的`gesture:`不符。新增独立固定公开selector测试先RED后GREEN，不能以产品与fixture共享同一错字符串自洽变绿。原错误、行为RED及修正日志保留。

## 3. 正式service断链返回前同步静止

原 `/Volumes/RC500/dev/safarier/Sources/Safarier/Automation/RunnerAutomationService.swift` 的server shutdown callback只排入MainActor Task，而serve直接返回；不应依赖调度顺序来保证停止输入。没有声称旧顺序每次必然失败，新增保证是显式同步时序。

- 原 `/Volumes/RC500/dev/safarier/Sources/Safarier/Automation/RunnerAutomationPage.swift` 增加强制同步quiesceInput，没有默认空实现。
- 原 `/Volumes/RC500/dev/safarier/Sources/Safarier/Automation/OwnedBrowserAutomationPage.swift` 仅委托已有input.closeActivity，不另写执行器或补mouseUp/drop。
- Service对已发布资源或已采用opening页面先full-identity-fenced quiesce，再原abort/controller cleanup；独立shutdownStarted保证幂等，不与已有stopped（也会因opening失败设置）混淆。
- serve拿到server status后同步shutdown再返回，保留原callback，重复调用不重复静止。异步destroy/storage cleanup沿原路径和预算，不把stop当作destroy证明或finish ack。

旧实现配fake普通quiesce方法的opening/active断言均有行为RED；失败夹具及非空清理失败日志保留。原service case扩充至63项：active/opening、重复、身份漂移不碰、迟到factory仍原销毁规则、pending gated fake action停止后不产生效果、真实AF_UNIX socket EOF时serve返回前quiesce。这是service契约验证，不是完整原生Runner/GUI闭环；fake action明确不是物理输入证明。

## 4. 主agent独立验证

| 验证 | 最终重复结果 | 边界 |
| --- | --- | --- |
| 原native bridge脚本 | 三轮各93 checks通过 | 原scope/异常/并发/光标检查保留；typed modern ABI/转发/nil/ownership覆盖 |
| 原service脚本 | 三轮各63 checks通过 | NSApp=nil，包含真实socket EOF、fake page |
| 原完整XCTest | 三轮各343 entries=340pass/3原条件skip/0fail | 不filter、不删断言；四目标真实执行 |
| 私有helper类型验证 | 27项通过 | 无NSApp、无drag调用；拒绝block及畸形/尾随编码 |
| ObjC桥x86_64 | 编译通过 | 未运行x86_64、Rosetta或VM |

XCTest每轮仍为WebKit77（skip2）、Network100、Core96、App70（skip1）。三个原skip不当成验收通过；Swift Testing的0 tests不用于计数。正式NativePageInput/Factory/defaultscript代码未因验证而放宽。

主agent还要求将新增native测试的fork后ObjC初始化改为posix_spawn/exec同一测试程序的新鲜子模式；不关闭ObjC fork safety。当前真实optional-absent与动态fixture-present分开，未来平台存在API时验证present，不伪造absence。最终计数93而非中间95是两个子进程创建/wait检查合并计数，旧断言语义未删除。最终三轮日志使用最终测试源。

## 5. 实际现代组件负例与legacy回归

主agent审阅、逆变换校验私有probe，编译链接当前产品Swift源、新ObjC桥和固定ObjC调用helper，独立签名校验通过。保留原fixture、NativeEvents及原25项/allPassed条件。原pre-App public-entry tripwire仍先安装，防止对照真正启动OS拖拽；本批不修改其旧证据。

ObjC helper仅构造自有NSEvent对象、局部NSPasteboardItem/NSDraggingItem与小图像，不post事件、不读写general pasteboard；固定typed方法返回id，转换为BOOL后才返回Swift。主agent复核修正helper原先过宽的类型首字符判断，现拒绝@?与畸形编码并核对完整冒号。

| 场景 | probe退出 | 原系统入口tripwire | 拒绝报告 | ObjC nil读回 |
| --- | ---: | --- | --- | --- |
| modern event disabled对照 | 71 | 命中event入口 | 无 | 未返回，进程被保护退出 |
| modern event enabled-1 | 0 | 未命中 | systemDrag，callInProgress=true | true，无exception |
| modern event enabled-2 | 0 | 未命中 | 同上 | true，无exception |
| modern event enabled-3 | 0 | 未命中 | 同上 | true，无exception |
| 原WebKit legacy enabled回归 | 0 | 未命中 | systemDrag，callInProgress=false | 不调用modern helper |

四轮enabled均只完成前15功能检查、原allPassed=false。停止后ready=false/status=OK；即时closed可能仍false，不冒充finish ack。最终driver trace与否决后快照逐项相同，没有后续up/drop或其它native输入，自身激活观测false、own global pointer events=0。event callback记录callInProgress=true，排除“早到legacy拒绝”被误判为modern成功；对照命中则证明测试并非仅因参数不能启动而返回nil。

每轮外部只读observer12秒/1200样本，始终NSApp=nil，覆盖否决时刻；五份实际报告schema均通过。对照计数稳定且只见基线cursor；enabled各轮有外部活动和多种cursor图像，读数全部保留，不能把所有变化强归因外部或据此宣布G5。这里支持的是固定入口拒绝与停止继续送入，不是全系统零干扰证明。

证据根目录：`/Volumes/RC500/dev/safarier/.build/automation-quiescent-shutdown-20261030`。精确汇总在`native-component-summary.json`、`full-xctest-summary.json`和`main-probe-review.json`。tripwire与外部observer因固定父目录仍写上一批私有目录，本批status/summary给出绝对路径，不覆盖旧记录。四种非法参数实际二进制均退出64，未创建输出，并在显式NSApplication.shared调用之前退出。

## 6. 下一步与保全

- 下一步要检查原fixture允许的custom-pointer/held序列为何升级为系统拖拽，完整重跑原25项与隐藏/遮挡/取消/退出矩阵；本批否决成功不能替代允许动作功能通过。
- 当前macOS没有gesture方法，仅有代码与动态fixture证明；不能声称其真实平台GUI验收。modern event组件也不是新版本WebKit现代调用闭环证明。
- 正式Factory→OwnedPage→Runner→AppleScript、异步finish ack、销毁/owned Runner收尾回执及真实并行文字/修饰键/IME仍未完整验收；不放开门禁。
- 不添加全局输入、焦点/光标/输入源恢复、假session或产品_exit。无提交推送、正常App安装/发布。仅本轮自有fixture/诊断进程操作，无真实Profile/账号使用。

本轮只改既有五个生产文件、两个原测试及原计划，新增本报告。既有无关dirty、兄弟仓库、缺失资源和工具路径按hash保全，source冻结与已持有诊断进程回收见`/Volumes/RC500/dev/safarier/.build/automation-quiescent-shutdown-20261030/final-review.json`。**现代event拒绝与断链先停输入已取得候选级验证；整个后台控制功能仍未放行。**
