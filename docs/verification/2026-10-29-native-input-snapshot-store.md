# 2026-10-29 共用原生输入实现与私有截图存储

## 结论与边界

- `/Volumes/RC500/dev/safarier`，分支 `mcc-safarier`，HEAD 仍为 `2f32d21248deaffd8c8c1152a39912aa46350c7e`；没有提交、推送、安装或发布。
- Terra worker 实现，主代理全部 code/design review 与独立反例/组合验证；重新读取 worker turn_context，均为 `gpt-6.1-terra` / `high`，没有 reviewer 子代理。
- 第六批完成**从原探针抽取的唯一 native 事件实现**、固定输入入口/内存快照候选代码和**真实 POSIX 私有文件存储**。不等于 Task 5/G0/G1/G2 已全量验收。
- 本轮没有运行真实 App、诊断探针、NSApplication、WKWebView、窗口、Apple Events 或 native/cursor 测试，没有注入用户鼠标键盘事件，没有访问真实 Profile 或截图屏幕。文件 fixture 只在本仓库 `.build` 私有子树中生成和删除。
- shipping admission 始终不可用；原 UI 工厂和页面服务的硬拒绝仍在。真实 renderer/native sink/对象与进程收尾没有接线。

## 1. 一条真实事件实现，不复制另一个执行器

`/Volumes/RC500/dev/safarier/Sources/Safarier/Automation/NativePageInput.swift` 从原 `/Volumes/RC500/dev/safarier/scripts/background-input-probe/NativeEvents.swift` 抽取同一套 native 构造、窗口坐标转换、hitTest、tracking owner、TLS 按钮、后台活动与 pending-mouse completion 路径。

- NativeEvents 现在只是诊断适配器：stub 不创建 driver、不发送输入；fixed 转发到同一 NativePageInput。适配器不再保留 NSEvent/CGEvent 构造、SFR 鼠标分发或另一份真实 completion 栅栏。
- 正常产品的 `requireShippingAdmission/open` 在任何活动 lease、NSApplication 或 WebKit 调用前拒绝。诊断构造及 trace 仅在 **SAFARIER_NATIVE_PROBE 编译定义**下存在，定义只加入 probe 构建脚本；不是运行时 force 选项，也不是 G2。
- Package.swift 只为 Safarier executable 增加已有 ObjCSupport 的显式依赖；资源、最低系统、产品和原测试目标保持。build-probe 仍编译原 App 源码集合，不重复加入同一驱动文件。
- 驱动严格绑定原 WebView/Window/windowNumber/bounds/frame/backing scale/pageZoom，检查真实非 key/main/active 状态和目标子树 responder/hitTest；不附着前台窗口或其它 App。
- mouseMoved 保留来自固定 WebView trackingAreas 的 NSObject owner 路径，不猜测私有 tracking owner 必须是 NSView；键盘 keyDown/up 继续走固定 selector 的原检查桥，不经 App 菜单。
- `/Volumes/RC500/dev/safarier/Sources/SafarierCore/AutomationProtocol.swift` 只在原 AutomationViewport 上补 contains；不重定义 viewport。真实输入预检复用 `/Volumes/RC500/dev/safarier/Sources/SafarierCore/NativeInputPreflight.swift` 的半开有限边界、按钮/几何/文本/滚动/shift 和完成门逻辑。

### 固定输入与完成语义

perform 仅接受固定输入子集，检查 viewVersion、按钮状态、有限坐标和长度后走上述实现，成功才递增 delivery sequence，返回 nativeDelivered。导航/会话/截图不从此入口任意执行。

- key 仅原固定键枚举；shift 仅 Tab/方向/Home/End，既不发送 Command/Option，也不保留全局 modifiers。forward Delete 使用对应固定 function-key 字符。
- insertText 使用原生 NSTextInputClient 的固定接口，不使用 clipboard、输入法切换、DOM/JS 或按未知 keycode 猜 Unicode；UTF-8 长度上限保持 16,384 字节。
- 当前滚动只接收已实现的垂直整数像素，拒绝横向、小数、非有限/超限值，不悄悄裁剪或取整。CGEvent 仅用于原有 private-state 滚轮事件构造，绝不 post。
- 鼠标使用检查过的 pending-mouse completion，等待真实完成且有界、可取消/检查 epoch；没有键盘完成 selector 的新猜测。文本/键盘回执只承诺原生 responder 调用，不能宣称 DOM 或业务已完成。
- 未知 probe mode/诊断键明确失败，不让无输入的 drain 静默成功。

### 收尾与内存快照

原探针 closeActivity 在 held 时补发 leftMouseUp，不符合正式安全设计，已移除。held、未完成鼠标栅栏、未知分发结果或先前销毁需求，都使 requiresOwnedTargetDestruction 保持为真。close 只结束活动/作废 epoch、拒绝晚到回调，不生成 up/click/drop，也不宣称 Runner 已退出。

诊断适配层可关闭自己固定的窗口；**Window.close 本身不证明 WebView 已销毁，也不证明 click/drop 为零**，实际持有取消/退出负例仍须隔离图形验收。

captureSnapshot 使用目标 WK 原生接口，返回内存 PNG 和原 AutomationViewport。一次完成门、5 秒预算、取消、epoch/几何复核防止重复或迟到完成；拒绝超过 4,096 边或 32 MiB，不自动截图、不静默缩放、不写任意路径。此方法本轮只编译，没有实际创建 WebView 验证。

## 2. 安全截图存储：真实私有文件测试

`/Volumes/RC500/dev/safarier/Sources/SafarierCore/AutomationSnapshotStore.swift`：Foundation/Darwin、锁串行的独立存储对象，复用原 limits/viewport/error。参数是未来拥有者提供的可信私有 baseDirectory，不是新的 wire 路径参数；生产绑定仍需固定到 SAFARIER_HOME 的 automation-artifacts 根。

- 对本实例随机 UUID 子目录使用 0700，随机文件名 PNG 使用 0600；不包含 session token、页面 URL 或输入文字。拒绝带 host/user/query/fragment/port 的 file URL。
- 逐组件 O_DIRECTORY/O_NOFOLLOW/CLOEXEC 打开并固定目录 fd、device/inode、UID/GID/权限；每次写入/返回路径/清理前复核链，拒绝符号链接、类型/祖先/目录替换和元数据变化。
- 文件 openat O_CREAT/O_EXCL/O_NOFOLLOW；固定文件 fd/身份、普通文件、当前 UID、单链接、0600。只对新建自有目录/文件清除继承的 macOS extended ACL 并回读，绝不修改 base/祖先 ACL。
- 8 份成功截图上限，同时把不能安全删除的失败对象/未知创建槽计入有界额度，防止“写失败不算成功”无限积累 FD/文件。
- PNG 校验**仅 signature/IHDR 尺寸**，不是完整解码/CRC 认证；未来拥有者必须传可信 native encoder 数据。像素边限/字节限、有限正 metadata，以及 pixel-to-logical scale 一致性在创建前检查，不重算或改写 metadata。
- 固定 600 秒 monotonic lifetime，操作/tick 观察过期即关闭；写入循环检查实际期限，连续 EINTR 有界。单次阻塞的内核 write 无法在此抢占，未来调用者须把存储 I/O 放到 MainActor 以外，并由真正 owner 驱动 idle tick/关闭。
- close 仅 unlink 已登记且当前身份/模式/ACL/单链接仍匹配的名字，关闭自己的 fd，不递归扫描或删除未知内容。目录非空、替换、symlink/hardlink/ACL 改变时保留并报告未完全清理；重复 close 稳定。

**威胁边界：**本实现检查的是当时的路径/对象身份。不能证明任意恶意同 UID 进程在返回 URL 后、或 identity check 与 unlinkat 之间不再修改文件系统；没有伪称公开 filepath 是不可替换的能力。0700/0600 与清 ACL 用于隔离其它用户，固定 fd/检查用于防止已知替换和误清理。

## 3. 主代理 review 修正

- 恢复原 NSObject tracking owner 与固定键盘检查桥，避免“更严格的类型假设”破坏原 hover 路径。
- 真实 driver 使用新 contains/button helper；补固定 shift 范围、UTF-8/滚动限制、forward Delete 字符。
- held/未完成/未知分发一律保留自身销毁要求；取消不补 up。快照增加有界一次完成/取消/epoch，回调状态明确在 MainActor。
- 存储把失败保留对象也计入额度；EINTR/短写循环观察真实期限，不冻结时钟或无限 retry。
- ACL 不等于 mode 位，补清除/回读；追加祖先元数据、URL 元信息、PNG/比例一致性检查。

这些由 Terra 修正，主代理读取实际代码/RED/GREEN 证据并写独立反例；不是 worker 自评审。原有 SFRRuntime/header、App UI 策略、Manager/Runner 启动和 shipping 开关均保留批次前 hash。

## 4. 主代理最终验证

证据目录 `/Volumes/RC500/dev/safarier/.build/automation-stage6-main-review/`；冻结源码、最终所有 Core 静态模块、命令/stdout/stderr/exit 与符号检查均保留。

| 验证 | 结果 |
|---|---|
| 联合共享 cases，3 轮 | 每轮前五批 1,847 + native preflight 60 + snapshot store 69 = **1,976 项**，exit 0 |
| 独立 native 预检，3 轮 | 每轮 **133 项**：有限半开边界、按钮、几何、Unicode 长度、显式滚动拒绝、并发一次性完成；无 AppKit/WebKit 实例 |
| 独立 snapshot，3 轮 | 每轮 **88 项**：真实 POSIX/ACL、quota、size、TTL、symlink/hardlink/inode/祖先替换、partial I/O、EINTR、保留对象额度与并发 close；仅私有 fixture |
| 前批独立反例，3 轮 | controller 67、UI boundary 225、session 356、policy 1,001、script 281、被动 sender 39 均通过 |
| 正常产品 actual admission | 直接链接正常产品实际对象，调用 NativePageInput 静态 admission，无需 WebView/窗口，准确返回 UI_POLICY_UNAVAILABLE |
| 正常产品/诊断模式 | 最终完整产品编译链接通过；用实际 App 源码和真实库对象加诊断 define 编译链接探针通过，**未执行探针** |
| 符号边界 | 正常产品 NativePageInput 诊断构造/trace 符号 0，诊断探针 9；nm 原始输出非 UTF-8 的其它符号保留 raw，以 ASCII 匹配检查，不改产物 |
| 真实配置工厂，3 轮 | 每轮 8 类背景配置提前拒绝，credential/privacy 调用 0；不创建 GUI |
| 旧协议/进程/启动/元数据 | request 71、reply 47、roundtrip 28、handshake 16、真实自有 Foundation 坏握手 5、reducer 299,592 transitions、metadata/sdef 32 全通过 |
| 独立脚本与正规测试限制 | native 60、snapshot 69 脚本通过；XCTest wrappers 仅语法检查，编译探针仍 no such module XCTest |

全产品使用已有命令级 Manifest VFS overlay 与新缓存，没有 patch SDK、改全局 developer directory 或安装工具链。原 XCTest、native/cursor strict runtime、真实 App/probe/输入矩阵都未执行；纯 helper/文件系统测试不能替代 hover、按住取消、IME、截图实际像素和窗口焦点验收。

## 5. 尚未完成与下一步

- G0 原完整测试/release/打包仍未通过；G1 真实路由/冷启动/焦点与 G2 完整 UI/原生输入负例仍未通过。53 项真实 UI 能力记录没有被提升为 active。
- 没有把 NativePageInput 或 SnapshotStore 接到 shipping Runner/AppleScript 服务，没有创建真正后台目标，没有真实持久权限读取、对象 UUID/进程退出证明。native 内存快照与私有存储目前是分离接口。
- 下一步沿原计划绑定真实专属目标/driver/store、受控通道与自身进程收尾，并准备隔离图形环境执行原矩阵及完整正式闭环。不能删 admission/factory guard、改 capabilities=active 或用全局输入弥补。
- 最终检查 **117/117** 通过：批次前186个文件中仅修改约定的Package/viewport/probe适配与构建共4个文件及2份设计/进度文档，另外180个保持hash；新增12个源码/测试/脚本文件和本报告，共13个。冻结源、系统工具链hash、全局developer directory及邻接仓库Git状态保持一致，自有helper遗留0、staging为空。证据见上述目录final-review.json。
- 本轮不提交、推送、安装、发布，不授权运行候选 App。
