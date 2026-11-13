# 本机 cursor 异常归因：确认 WebKit 发起系统拖拽

日期：2026-10-30（Asia/Shanghai）。仓库 `/Volumes/RC500/dev/safarier`，分支 `mcc-safarier`，HEAD `2f32d21248deaffd8c8c1152a39912aa46350c7e`。本轮继续上一轮 cursor 安全失败归因，不恢复 VM，不开放正式输入。实现由 Terra worker 执行，全部 code review 与真实诊断执行由主 agent 完成。

## 结论与边界

**已确认一个真实安全缺口：当前原生页面事件路径会在自有 BrowserWebView 未激活时，异步经 WebKit `WebViewImpl::startDrag` 调用 AppKit 系统拖拽入口。** 连续三个独立诊断进程均捕获同一路径；诊断器在原拖拽方法执行前记录并 `_exit(71)`。其中两轮，外部只读 observer 的两种状态下 14 类输入计数全程零变化，32 个 combined 按钮状态均未按住，仍发生自有 WebView 的系统拖拽请求。

这不是“原始 TIFF 编码差异”，也不是“外部用户输入可以解释所有变化”。旧异常帧未保存调用栈，不能把新证据描述成直接记录了旧帧的全部因果；但已建立与旧失败相同的按住阶段、可重复的自有系统拖拽逃逸证据，必须先解决此缺口。

**尚未修复正式执行器，也未证明生产后台操作安全。** 本轮成功的是归因与诊断拦截，不是原 25 项功能全部通过：三轮均只完成前 15 项后主动退出，没有最终 `report.json`，后续 release/scroll 等未执行。诊断退出 71 是预期 fail-closed 结果，不能写成测试失败已消失或矩阵通过。Factory、Native、默认脚本入口门禁不变。

证据根目录：`/Volumes/RC500/dev/safarier/.build/automation-cursor-attribution-20261030`。原失败仍在 `/Volumes/RC500/dev/safarier/.build/automation-full-xctest-20261030/native-runs/background-1/report.json`，不覆盖、不改原断言。

## 1. 取回同 hash 的原始异常图像

- 本轮最初一次原判断不变、仅保存图像的 paired repeat，捕获旧异常 SHA256 `ef6d71540be9ba0eac3f45328171cb3c864e267d29ee24c15467a353f958529d`。内外 observer 均观测到该图像；该轮存在外部鼠标与键盘计数变化，不能作为静默环境安全验收。
- 基线 SHA256 `57a1d610df3e421ebef670ba58c97319d2ab6990d64dca34d28140e4527fd54d` 为普通箭头；异常图像经主 agent 实际查看，是带绿色加号的箭头复制拖拽样式。这里只描述图像，不单凭外观归因调用方。
- TIFF 多表示确实从四份变两份，但共同 28×40、56×80 表示也分别存在 487、1892 个非透明 RGBA 像素差异，alpha 分别变化 479、1850；不是仅透明 RGB、ICC 或序列化元数据。未压缩原始 raster 比较也确认差异。不能通过忽略 metadata、高分辨率表示或坏帧来放行。
- 对应原始 TIFF 位于上述证据根目录的 `paired-1` 子目录；解码比较、stored-raster 和 PNG 证据亦在根目录。新增只读比较工具的 8 项离线回归由主 agent 独立执行三轮通过，不含 safetyPassed 结论。

## 2. 排除一个较简单的观测副作用假设

独立无 NSApplication、无窗口、无 WebView、无事件投递的 query-scope 小程序，复用现有 `SFRWithScopedMouseButtons`：十轮嵌套 0→1→0，共 50 个读数；逻辑按钮切换与 IMP 恢复均符合预期。内外只读 cursor 图像均保持基线，外部 400 样本 NSApp=nil。它仅说明单独按钮查询不足以复现，不能排除 WebKit/异步组合行为。

另一次主 agent 的 headless 标准 cursor 工厂枚举校准未生成报告，最终退出 139；没有采纳为证据，也没有反复初始化 GUI 重试。失败源与产物留在证据根目录的 `palette`；它不是产品测试通过或产品修复。

## 3. 在系统拖拽入口前 fail-closed 取证

Terra 仅在证据根目录的 `drag-trap` 子目录实现 helper 与私有 probe 副本，没有修改生产 bridge、driver、fixture 或原 probe 源码。

- 固定公开 selectors：`beginDraggingSessionWithItems:event:source:`、可用时 gesture 变体、`dragImage:at:offset:event:pasteboard:source:slideBack:`；固定类为 NSView、NSWindow、WKWebView。先校验所有 return/argument ABI 与继承覆盖，再替换当前进程 own methods，未做无界类扫描或私有 selector 猜测。
- 本机 manifest：NSView 与 NSWindow 分别 own modern/legacy 四个入口，WKWebView 继承这些入口，gesture 变体 runtime 缺失。生产模式编译使用本机 SDK，不把新 SDK 的可用性声明当运行时存在证明。
- 安装在 `NSApplication.shared` 前，实际日志 `nsAppExists=0`。新 trace 仅能写本次固定私有目录的直接子文件，O_EXCL/O_NOFOLLOW、0600，目录 0700，不能覆盖现有 trace。记录 uptime、selector、receiver class、own PID、main thread、app active、event type/window number 与调用栈；不读 pasteboard、不读用户按键文本。
- 命中后绝不调用 original，fsync 后仅结束当前自有诊断进程；日志失败同样结束。没有对 nonnull session 返回 nil/fake 对象，也没有让 NSException 穿越 Swift 来伪造取消。没有全局输入、恢复鼠标/焦点或补发 mouseUp/drop。
- 私有 probe 副本只增加安装调用与 case name/passed/time checkpoint。主 agent 逆变换确认逐字节等于此前 observation-only 副本；原 25 项条件、`allPassed`、fixture、原生执行器及动作顺序保持不变。
- 主 agent 独立重复 dummy suite 三轮通过，覆盖 modern/legacy ABI 拒绝发生在 swizzle 前、入口退出 71/原方法未执行、日志失败退出 70、0600/no-overwrite/symlink、重复安装及空 trace 拒绝。ObjC/Swift 编译与独立诊断 App 严格签名校验成功；真实诊断二进制缺少 trace 参数时退出 70，未进入 probe 初始化、未产生 pid/report。
- Worker 在收到“实际 AppKit 安装留给主 agent”的补充前做过一次无 GUI/输入的安装校准，历史 `native.trace` 已标明是旧修订，不能替代主 agent 的最终三轮验证；没有 worker 执行真实 GUI/probe。

## 4. 三轮实际捕获

| 轮次 | 自有 PID | 入口 | 命中状态 | 距最近 held case | 进程 / observer 退出 |
| --- | ---: | --- | --- | ---: | --- |
| 1 | 13101 | legacy dragImage | main thread，appActive=0，receiver=自有 BrowserWebView KVO 子类 | 18.83 ms | 71 / 0 |
| 2 | 13972 | legacy dragImage | 同上 | 22.46 ms | 71 / 0 |
| 3 | 14058 | legacy dragImage | 同上 | 11.74 ms | 71 / 0 |

每轮 checkpoint 前 15 项全部通过，最后一项都是 `held_state_is_process_local`；随后 WebKit IPC 回调进入 `WebPageProxy::startDrag` → `WebViewImpl::startDrag` → legacy AppKit 拖拽入口，尚未记录 held release 就被主动停止。接收者不是其它 App，不是观测器，也不需要猜测具体拖拽内容；本轮没有读取拖拽数据。

外部 full observer 每轮 12 秒 / 1200 样本，始终 NSApp=nil，均覆盖入口时刻。首轮有外部左右键与移动计数变化；后两轮两种状态全部 14 类计数无变化、32 个按钮均 false、全程只见基线 cursor hash，采样 foreground PID 各自稳定。这些是有限类别采样，不等于绝对硬件来源证明、覆盖所有手势或正式持续打字/IME 验收。源状态名仅按 API 记录，不宣称其绝对物理来源。

精确 correlation、manifest、trace、checkpoint、退出码与各轮计数见：

- `/Volumes/RC500/dev/safarier/.build/automation-cursor-attribution-20261030/drag-trap-correlation.json`
- `/Volumes/RC500/dev/safarier/.build/automation-cursor-attribution-20261030/drag-trap-main-review.json`
- `/Volumes/RC500/dev/safarier/.build/automation-cursor-attribution-20261030/drag-trap/observed-1.trace`（2、3 同名序号）

## 5. 对现有实现与原安全 oracle 的含义

生产 `systemDrag` 目前只有 Core policy/catalogue 声明，没有实际 AppKit drag-source 拦截；catalogue 本身也没有宣称控制已安装。现有 cursor guard 保护 NSCursor 的 set/hide 类入口，无法据此声称已防住系统拖拽会话。`NSEvent.pressedMouseButtons` IMP 恢复正确，同样不代表 WebKit 没有将已送达的按住序列升级为系统拖拽。

原 probe 的 global pointer monitor 只覆盖左键、移动、滚轮；只要外部输入存在就允许 cursor hash 变化。因此它在并行人工输入时可能仍给 25/25，但不能排除自有系统拖拽导致的 cursor 变化。保留原判据没有改绿，正式 G2 必须另有可验证的展示前拖拽控制，不能凭此探针 allPassed 放开。

## 6. 下一实施批次：复用现有原生路径封堵，不新增兜底执行器

按已批准设计 Task 2/5/8 推进，不另起页面输入架构：

1. 基于现有 `/Volumes/RC500/dev/safarier/Sources/SafarierObjCSupport/SFRRuntime.m`、`/Volumes/RC500/dev/safarier/Sources/Safarier/Browser/BrowserViews.swift` 与原 BackgroundPagePolicy/owner，设计并验证专属后台目标的 **系统 drag-source 展示前拒绝**，覆盖本机实际 legacy 和现代入口，人工模式维持原行为。
2. 不把本轮诊断的全进程入口 trap 直接当成产品补丁。现代入口 nonnull，不能 nil/fake-return；若无法安全取消并通知现有会话 owner，则保留能力 false、拒绝准入。任何不得不结束专属 Runner 的路径须接入现有 owned lifecycle/错误回执/绝对收尾预算，并证明不影响人工窗口，不能仅复制 `_exit`。
3. 遇到系统拖拽企图使用既有 `.systemDrag → cancelAndSuspend` 语义，停止继续送入；无法证明本地取消安全时销毁专属目标/自有 Runner，不补 mouseUp/click/drop，不恢复全局 cursor、焦点、输入源或修饰键。
4. Terra 实现、主 agent 唯一 review；先写负例与人工模式保真回归。刻意可拖拽文本/链接/图片/HTML 不得启动 OS session；原 hover/range/text/custom-pointer/down/up/scroll 路径应在安全能力证明后重新完整跑原 25 项与原矩阵，不删原检查换绿。
5. 再做隐藏/遮挡/取消/退出等矩阵与真实并行输入验收，明确分开“计数零变化”和实际文字接收/修饰键/IME 证据。禁止向用户前台 App 合成全局按键制造测试数据。

## 7. 保全与交付状态

本轮以 282 个已有文件为基线，写业务文件前已核对全体不变。仅追加原计划并新增本报告；诊断实现和证据只在私有 `.build` 下。上一轮冻结的 250 个代码/测试/脚本文件不得漂移；生产 Native/Factory 门禁仍关闭，默认脚本入口不变。上一轮 full XCTest/正常 App 构建成功是历史证据，本轮没有假称重跑它们。

无 VM、全局输入 fallback、光标/焦点恢复、真实 Profile/账号/pasteboard 内容读取，无提交、推送、正常 App 安装或发布。只启动自有诊断进程，三轮均自行退出并被父进程 wait 回收；未按名称清理他人进程。最终 hash、兄弟仓库状态、缺失资源及进程审计见 `/Volumes/RC500/dev/safarier/.build/automation-cursor-attribution-20261030/final-review.json`。**归因已取得确定进展；正式修复与 G1–G5 尚未完成。**
