# Static Role Candidate — 实施计划

> **给执行者：**只实现用户已批准的静态角色方案，不扩写集或另建认证框架。主 Agent 是唯一 reviewer；本计划不授权自动 commit、运行 GUI 或更改 TCC。规范：`docs/superpowers/specs/2026-11-05-mcc-safarier-static-role-design.md`；逐项 namespace、固定 SHA 与写集以 `static-role-20261105/contract.json` 为准。

**目标：**一个外层候选 App，固定独立签名的内嵌 Runner；复用真实 owned/Binder/socket/native 链，在不放宽验证的前提下消除同一控制 BID 的角色冲突。

**实施前源码基线：**外层控制 BID `sh.safarier.boundcandidate`；已有 Core 验证同一 binary、RunnerLauncher 默认当前 executable、main 按 argv 分流，均须沿原路径适配。先协调自／对端静态 pin 语义与可用 C API，避免 tools 对未定 Core 契约猜测；不在当前步骤执行生产代码或构建。

## 写集与证据分工

- **Core worker 独占：**合同 `coreWriteSet` 的 `BoundBundleRoles.swift`、`KernelIdentityBridge.swift`、`BundleResourcePin.swift`、`RunnerLauncher.swift`、`AutomationRunnerClient.swift`、`AutomationRunnerServer.swift`；不修改 BinderIdentity／BundleInventory／SFRRuntime C、headers、Package 或协议／预算。
- **Terra tools/App worker 独占：**合同 `toolsAppWriteSet` 的 `build.py`、`run.py`、`SwiftHost.swift`、`Sources/Safarier/main.swift`；本 spec 与本 plan 为文档写集。保留所有其他 worktree 编辑，不 reset/stash 或覆盖历史 artifact。
- **main：**唯一 review、并行写集冲突裁定、冻结输入、产物／签名／pin 独立固定、授权何时运行每个真实步骤及最终交付。负例及日志使用本合同的新 stage；不额外修改未授权测试源码。

### Task 1 — Core 静态角色对与原 launcher

- [x] Core 与 tools/App 先确认封闭的语义接口：从 C 核验的 self 得到固定角色对；对端 pin 与完整父 inventory 从同一已验证结构取得；产出仅供原 owned launcher 的精确 Runner 路径。不要把 argv／env／BID／role 或候选包内可变 manifest 当 authority。
- [x] 在合同 Core 写集适配 `KernelIdentityBridge` 的 self／peer 分离：Main 与 Runner 分别捕获自己的 static/self evidence，并使用 opposite role pin 验证原 retained child／actual parent、birth／ppid／uid/path 和 socket peer；每次原有检查继续覆盖父 19 路径、Runner 8 路径及其签名／固定资源。无身份证据即拒绝，不借共同签名者兜底。
- [x] 在原 `RunnerLauncher`、client/server、context 及 fixture URL 路径中使用经验证的内嵌 Runner；保留实际 held lock loan、单一 reader、writeQueue、Pending、hello/ready 后绑定、原 timeout／cleanup。非 candidate 的普通运行不变；不可用现有 C API 表达时报告 main 并停止，不改 C 或造新通道。
- [x] 完成后提供逐文件本轮 before/after diff、与冻结基线的 SHA、角色关系和失败关闭证据；由 main 唯一 review。此项完成不代表真实 GUI 成功。

### Task 2 — Tools 打包与 App 入口

- [x] 在 `build.py` 复用 metadata-only 和原正常 SwiftPM 路径；为新 stage 创建独占 attempt／scratch/cache/TMP/config/security，固定源码前后 SHA；仅 normal `swift build --product Safarier`，不运行 release、lipo、外部 helper 或全量测试。
- [x] 从原 exe 组装精确 Runner 8 项并先签、strict verify；Main 原资源与完整 Runner 组成精确 19 项后再签、strict verify。两份 fixture 与 Main sdef 固定 SHA，Runner 不带 sdef；分别保存两端 Info/exe/CodeResources 和完整清单。禁止包内自信任 manifest、symlink、已存在输出覆盖及删除旧产物。
- [x] `main.swift` 仅做与 Task 1 经验证角色对一致的入口分流；参数／Bundle 信息不是授权。调整 `run.py`／`SwiftHost.swift` 仅到新静态结构所需的 pin、独占 workspace、真实 sender 生命周期和观测；保持 false-preflight、OSA noPrompt／neverInteract、原 event 白名单和 same-BID `count == 1`。
- [x] 提供 tools/App 独立 diff、产物／构建记录格式和交互式／非 candidate 未变边界；由 main 唯一 review。Core 尚未冻结时不得把尝试构建当交付。

### Task 3 — 一次构建与少量静态签名负例

- [x] main 确认两项代码和角色接口后冻结源；在新 stage 运行一次 `python3 scripts/bound-control-candidate/build.py`，保留实际 argv、受限 env、stdout/stderr、exit 与源码 before/after。任一源码变化或构建失败停止；不可自行重复大矩阵或改他人文件。
- [x] 主 Agent 独立固定完整外层与 Runner 的 Info/exe/CodeResources、fixture/sdef pin；分别严格验签及核对 19／8 项 namespace 和无 symlink。父完整清单必须包含子 bundle 所有 bytes 和嵌套签名，不能仅看外层 `codesign` 退出码。
- [ ] 已执行四项实际 C 定向拒绝：Main 错 BID、Runner 错 leaf、原父 pin 后 Runner fixture 变更、父 namespace 额外项。**helper Info 篡改及重签负例未覆盖**，本项尚不能标为全面通过；不擅自补跑或扩展至 ASan、全量 tests 或历史矩阵。
- [ ] 任一现有 C API 无法实现角色交叉绑定、父子 revalidation 或负例无真实拒绝时停止，交 main 决定；不得将相同 TeamID、BID、表面 path 或假 peer 作为通过依据。

### Task 4 — 固定 fixture 真实 GUI 小闭环（已按主 Agent 派发完成；范围有限）

- [x] 主 Agent 在新内部 `0700` root 独立核验目标 App、两端 pin 与 sender、签名、namespace 和源码；创建隔离 `workspace/locks 0700`、`profiles.json 0600` 的 opt-in ephemeral profile，不改 HOME 或真实资料。所有 argv／环境／结果写入新 stage，session token／payload 只在内存。
- [x] 同一 retained sender 先启动精确 Main，核对实际 owner/birth/URL 与同 BID 唯一注册；对 `SFAu/requ` 执行 `ask=false`。非 0（含需授权）立即停，不触发提示、不切换 sender；OS prompt 需独立用户授权。
- [x] 只对固定 fixture 走真实 sdef/OSA 链：capabilities → openSession → getState → hover → screenshot → drag down/move/up → closeSession。每次入口和实际原 native commit 前保持 C pin／父子 peer／held lease／上下文检查，任何不符停止；不能改成 DOM dispatch、PID 路由或全局输入。
- [x] snapshot 若产生，仅从新 workspace 的受控 artifact 子树 no-follow／owner／mode／nlink／size 核验后独占复制到新 evidence；不以响应 path 作为删除授权。记录实际 receipt、可观察 fixture 结果和必要时图片，不能以解码或原生回执替代可见行为证明。
- [x] 正常 close／drain 后仅对原 retained Manager／Runner 依原 fresh birth 证据做有界 cleanup；超时或身份未知标 `cleanup_unconfirmed`，不扫描、不按登记或 PID 文件杀、不恢复焦点／光标。分别交代签名、Core、权限、真实 GUI、图片及 cleanup 结果，未覆盖为 unknown；不宣称完整 G1/G5、shipping 或键鼠不受干扰。

**历史首轮结果（部分）：**实际 same-BID `matchingCount=1`、Manager registered、Runner 在该注册快照中未登记，原同一 owned endpoint 经 Core 往返验证；capabilities、openSession、getState 成功。首个 hover move 返回 `INDETERMINATE_RESULT`、副作用未知；无截图，drag／closeSession 未执行，整体退出 1。Manager 原 retained Process 退出 status 15 已观察；Runner 独立退出观察未知。不可重发原 hover、复用旧 session，或将本项标为完整 GUI／G1／G5／shipping 成功。后续诊断需另行授权。

**历史：Task 4 当时部分进展（2026-11-05）：**两次新 session 均有真实 hover completion、绿色 fixture 截图及完整 pointer sequence 1–5／buttons 0、0、1、1、0 回执；两次 closeSession 均未通过原 `cleaned` 门禁，总 exit 1，Runner 独立退出未知。Task 4 仍未完成，Task 3 未覆盖的 helper Info／重签负例仍未覆盖；详见 `/Volumes/RC500/dev/safarier/docs/verification/2026-11-05-hover-native-ack.md`。不宣称完整 GUI／G1／G5／shipping 或人工并发键鼠长期不受干扰。

**Task 4 最新状态（2026-11-05）：**固定本地 fixture 的原完整链和真实 page／store close proof 在两个新 session 均 smoke exit 0，Manager final receipt 均为 cleaned／owned exit true；范围与证据见 `/Volumes/RC500/dev/safarier/docs/verification/2026-11-05-close-session-proof.md`。完整链指既有 smoke 动作与门禁；可见效果核对的是 hover 截图，drag 仅按原生回执和按钮状态验证，未声明 DOM 拖拽效果或完整 G5 验收。仅该固定 fixture 小闭环完成；Task 3 helper Info／重签负例仍未覆盖，不代表任意 URL／键盘、人工并发键鼠长期、完整 G1／G5 或 shipping 已通过。
