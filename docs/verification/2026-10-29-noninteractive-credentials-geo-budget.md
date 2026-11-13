# 第十一批：无交互凭据查询、代理凭据派发与 Geo 总预算

日期：2026-10-29。分支：`mcc-safarier`；HEAD：`2f32d21248deaffd8c8c1152a39912aa46350c7e`。

## 结论

本批完成**既有模块内的候选能力与无图形验证**：无交互凭据读取、前后台代理凭据派发、共享 Geo 解析的总预算检查。没有新建第二套凭据存储/网络管理器，没有启用后台页面操作。生产实现为三名实际 Terra/high worker，全部设计、code review 与独立反例由主代理执行。

Native、Factory、Manager cold-launch 和默认脚本门禁继续关闭。实际 Keychain、curl/网络、Profile、App/GUI/native/probe/AppleEvents/鼠标键盘操作均未执行。下列结果不等于真实 macOS 交互行为或不干扰验收通过。

## 源码复用与功能

### 1. 现有 CredentialStore 增加独立的无交互读取能力

文件：`/Volumes/RC500/dev/safarier/Sources/SafarierCore/CredentialStore.swift`。

- 新协议 requirement `passwordWithoutInteraction(forKey:)`，默认实现直接抛 `CredentialStoreError.interactionRequired`，不调用普通 getter。未实现能力的 backend 不能被自动当成安全 backend。
- InMemory 复用原锁内读取，Keychain 复用原 service/account/class 查询组装。原 Keychain 普通 `password`、`setPassword`、`removePassword` 三个函数保持原代码；不改变正常人工访问、写入或删除行为。
- 新 Keychain 读取仅设置 `kSecUseDataProtectionKeychain=true` 的 Data Protection 查询，并为每次请求创建独立 LAContext、设置 interactionNotAllowed、完成后 invalidate。Core 增加平台 LocalAuthentication framework 的使用，未引入外部包或修改 manifest。
- 查不到返回 nil；需要交互/认证失败/取消映射 interactionRequired；其他 OSStatus 保留 keychain(status)，非 Data 或非 UTF-8 的成功 payload 视为 errSecDecode。单次查询，没有 legacy retry、全局 UI 设置、evaluate 认证调用或自动修复写入。
- Security read 注入点为 internal，仅便于 @testable fake callback 验证生产查询；没有公开环境开关或默认 test backend。

**为何不能查旧域：** 本机 SDK 的 SecItem.h 明确 legacy 项可能无视 no-auth-UI 而出现 UI；LAContext.h 把 interactionNotAllowed 与该行为相联系。本批选择更保守的 Data Protection-only，未迁移、复制或读取用户现有密码。契约原文摘录保存在 `/Volumes/RC500/dev/safarier/.build/automation-stage11-main-review/sdk-credential-contract.txt`。这验证了实现依据与查询形状，不是实际 Security 服务/签名 App/授权域的运行验收。

**仍有供给限制：** 原普通 setter 仍写原域，因此不能假定用户已有的 legacy 凭据已能用于后台。需要独立、显式人工授权的安全供给/迁移流程；当前缺失就失败，不自动回退或复制。

### 2. 原 Factory 内唯一凭据派发

文件：`/Volumes/RC500/dev/safarier/Sources/SafarierWebKit/WebViewConfigurationFactory.swift`。

- make 仍以 requireExecutionPolicy 的 interactive-only hard deny 为第一操作，未开放后台配置创建。
- 原读取抽成内部 `proxyPassword(for:credentials:executionPolicy:)`，make 只调用一次。
- 人工模式保留原语义：username 非 nil（包括空字符串）仍调用原 getter；nil 不读。
- 后台候选只调用无交互 getter；缺失或 backend 不支持/需要交互均为 typed INTERACTION_REQUIRED，没有 nil 当空密码、重试旧 getter 或改为直连。
- 主代理对照原 ProxyConfigurationBuilder 发现：空 username 本来就不会 applyCredential。因此后台 nil/empty username 都不读取任何凭据，但仍保留所选代理；人工 empty 的旧行为不改。

`/Volumes/RC500/dev/safarier/Sources/SafarierCore/RunnerPreparationPlan.swift` 只移除旧的用户名 blanket 拒绝：允许规划认证代理的**元数据**，不代表密码可读或后台已放行。后台订阅、followProxyLanguages、followProxyTimeZone 等其余 guard 原样保留。

### 3. 原 Geo resolver 共用内核，增加总预算重载

文件：`/Volumes/RC500/dev/safarier/Sources/SafarierNetwork/ProxyGeoResolver.swift`。

- 原 API 仍 nonthrowing、同样 endpoint/hint 顺序与每次 timeout；解析、locale 表、hint 推断与 curl 代码保持原代码。
- 新重载传 absolute monotonic deadline、now、**显式 fetch**，走相同 resolveCore，不复制第二套解析/顺序。
- 每次 fetch 前按 min(timeout, remaining) 传递预算，不向上取整；返回后、hint 前及最终返回前检查过期、任务取消与非有限/倒退时钟。迟到的成功或 nil 都不能继续重试或变成 hint 成功。
- 新错误为 invalidBudget / timeout / cancelled / invalidClock，不携带密码或响应正文。

**明确限制：** 这是合作 fetch 的预算记账和迟到结果拒绝，不会强制中断任意同步函数。新重载没有默认选择旧 curlFetch；旧 curl 的 floor1 / +2 grace 行为未改，不能当成严格总墙钟上限。本批未接通/运行真实后台 Geo 子进程或 execv，Core plan 仍拒绝 follow flags。

## 主代理复核与测试同步修正

- 复核并确认 Data Protection-only，不能把普通/legacy Keychain getter 的 try? 或重试当成后台能力；default protocol 同样 fail closed。
- 按原 ProxyConfigurationBuilder 的非空用户名语义修正后台 empty username，不为无认证代理多读 Keychain，也不改变人工行为。
- 首次联合回归失败于旧 OwnedRunnerCases 的 `exit observed before first waiter`。原 fixture 只轮询 500 次、每次 sleep1ms，且未保存当时 observedExit 的具体快照。**无法从旧输出确认该次失败的具体原因。** 生产 OwnedRunnerProcess/RunnerLauncher 均与基线相同；随后独立 12 次实际自然退出的观察为约4–16ms，未复现首次失败。
- 识别到旧测试把首次进程加载/回调调度隐含限定到约500ms，而待测契约是“首次 owned waiter 前已有实际退出可缓存”。由 Terra B 最小修正测试：在绝对 monotonic3 秒 setup 上限内等待已有 Observer 的实际 onExit，再保留原 observedExit.status==7 与后续所有原断言；不先调用 owned.waitForExit，不改生产超时或清理预算，不 skip 错误退出。
- 初次失败、旧冻结哈希与调查结果均保留：`combined-round-1-first-observation-failure.*`、`initial-frozen-source-hashes.json`、`owned-observation-timing.*`、`fixture-correction.json`。后续若 3 秒收不到实际退出仍失败，不把本次三轮绿色说成已证明首次单次原因。

## 最终冻结验证

证据根目录：`/Volumes/RC500/dev/safarier/.build/automation-stage11-main-review/`。

| 验证 | 当前结果 | 边界 |
| --- | --- | --- |
| 冻结 code files | 233 文件 | Sources/Tests/scripts 哈希一致 |
| 联合 Core/Network/IPC/会话/权限/Manager 回归 | **3轮，每轮2,340 checks** | 既有2,228 + preparation46 + fake Security27 + fake Geo39；不是 XCTest/GUI |
| 主代理独立 credential query | 43 × 3轮 | 注入 fake Security，验证域/上下文/状态/一次查询/不回退；不查真实 Keychain |
| 主代理独立 Geo | 30 × 3轮 | fake fetch/clock，含预算递减、迟到、取消、非法时钟与旧 API 兼容；不跑 curl |
| 独立 preparation / 真实 workspace reader | 20 / 10，各3轮 | 认证仅元数据规划；私有 JSON，真实 Repository 绑定与错误传播 |
| 实际产品对象链接的主代理 Factory dispatch | 30 × 3轮 | nil/empty/user、无安全 backend、缺失/交互/其他错误、人工兼容；不创建配置或 NSApp |
| 实际产品对象链接的共享 Core + WebKit cases | 27 + 18，各3轮 | 同生产 query 和 helper，fake Security；NSApplication=nil |
| 既有实际 prepare/Entry / Factory / Native / Model | 28 / 8 / Native拒绝 / 12，各3轮；旧Entry6亦通过 | unavailable 回包和 early gate，NSApp=nil；无真实 Apple Event |
| 既有独立 policy/controller/session/script/snapshot/owned IPC 等 | 各3轮通过 | 合成53项 policy 不是真实53项 UI 验收 |
| 正常产品 / 诊断目标 | 编译链接 exit0，无 warning | 不运行 App 或 probe；正常诊断符号0，诊断目标5 |
| Metadata / 源码接线 | 32 / 新6+旧15，通过 | metadata-only 与结构检查，不是冷启动 OS 验收 |
| 新3个 XCTest wrappers | parse通过 | 实测 import XCTest 仍 no such module，未运行完整 swift test |

主要复现入口（只在证据目录运行无图形验证）：

- `/Volumes/RC500/dev/safarier/.build/automation-stage11-main-review/Validate.py`
- `/Volumes/RC500/dev/safarier/.build/automation-stage11-main-review/Stage11Independent.py`
- `/Volumes/RC500/dev/safarier/.build/automation-stage11-main-review/Stage11QA.py`

## 工作区保全与尚未完成

248 个基线文件中，241 个不变；限定修改4个生产文件、2个测试文件、正式计划共7个。新增11个测试/脚本文件及本报告，共12个；未新建生产实现文件。相邻 chrome-control-cli checkout 与10个原缺失资源保持。沿用命令级 VFS overlay/独立缓存，不修改系统工具链；xcode-select 与5个既有工具链保护文件核验保持不变。

没有 staging/commit/push/install/release，没有改 TCC、权限、默认脚本启用或真实 Profile。后台仍不能实际用于网页控制；订阅的 owned-only 生命周期、安全供给凭据、真实有界 curl/重启、AppKit 事件循环和隔离 G0/G1/G2/53项UI/其他App输入对照验收仍未完成。任何一步失败都继续明确拒绝，不采用全局鼠标键盘、System Events、焦点恢复或 DOM/JS 输入兜底。
