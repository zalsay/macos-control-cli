# 页面内拖动夹具归因与9×25诊断矩阵恢复

日期：2026-10-30（Asia/Shanghai）。仓库 `/Volumes/RC500/dev/safarier`，分支 `mcc-safarier`，HEAD `2f32d21248deaffd8c8c1152a39912aa46350c7e`。本轮基线286个已有文件；Terra实现、主agent唯一code review和独立实际执行。无VM、全局输入或恢复光标兜底。

## 结论

**原“custom-pointer/held升级系统拖拽”的可重复原因是测试夹具未实际禁止选中文字，不是本轮需要修正原生事件执行器。** 当前宿主WebKit不支持夹具只有无前缀的`user-select:none`；首次自定义拖动选中11字符，二次按住再移动是在拖已选文字。已有系统拖拽安全边界正确拒绝。

只补兼容前缀、不改可执行代码的因果对照恢复原25项；随后同步更严格的原oracle，在后台/遮挡/隐藏各三轮，**9轮×25=225项全部通过**。正式Factory/Runner/AppleScript闭环与持续并行打字/IME未完成，shipping门禁不开放。

## 1. 两轮未修正baseline：读实际行为，不凭CSS文本猜测

使用只读私有fixture观测副本，原NativePageInput和原ObjC bridge不变；原25判断和动作顺序未变。仅添加被动drag消息与只读snapshot，未preventDefault、dispatch事件、修改CSS/选区/焦点。消息限定own WebView/mainframe/fixture URL，JSONL为0600并有行数/字节上限，不记录拖拽内容或密码。

两轮baseline均记录：

| 观测 | 两轮实际值 |
| --- | --- |
| CSS.supports(user-select, none) | false |
| CSS.supports(-webkit-user-select, none) | true |
| customdrag computed -webkit-user-select | text |
| 首次拖动后选区 | customdrag anchor=1/focus=12，长度11 |
| 选区rect | [619,250,79.84375,18]，包含下次按住点[620,260] |
| dragstart | target=customdrag，trusted=true，defaultPrevented=false |
| dataTransfer types | text/html、text/plain；未读取内容 |

这与真实鼠标拖已选文字的行为一致，也解释了先前复制拖拽光标线索。本轮不重新放行系统drag来制造光标变化；产品deny与外层public-entry tripwire一直保留，原系统方法未执行。

`NativePageInput-observed.swift`等初始诊断草稿仅保留为未采用产物；实际baseline未链接该副本，未增加cgEvent getter读数，不把潜在materialization副作用当归因证据。上游WebKit源码仅留作线索快照，不冒充已安装build的精确源码。实际CSS/DOM/native结果才是本轮结论依据。

## 2. 因果对照：仅CSS资产不同，代码TEXT一致

同一编译结果复制成两个私有App，唯一CSS delta为在原声明前加入`-webkit-user-select:none;`。重新签名后两个Mach-O `__TEXT` SHA256仍相同；没有改变输入事件、动作、guard、原25条件或页面行为监听器。

补前缀后：computed prefixed值变none，选区长度0、没有drag消息/deny/tripwire命中，原25全部通过。证据为`css-only-causal-control.json`和`observed/causal-prefixed-1/report.json`，位于本轮证据根目录。

## 3. 最小修正与加强回归

三个既有文件：

- `/Volumes/RC500/dev/safarier/scripts/background-input-probe/fixture.html`：仅在customdrag控件增加`-webkit-user-select:none`，保留原无前缀声明；没有加user-drag:none、preventDefault或清选区。snapshot新增customDragSelectedLength，只要anchor或focus任一端点在customdrag中就计入；合法textarea选择不算作custom控件选择。
- `/Volumes/RC500/dev/safarier/scripts/background-input-probe/ProbeMain.swift`：原custom_pointer_drag_buttons的moves>0断言保留，并新增selectedLength==0。原25名称/动作顺序、其它判断不变，字段缺失不会默认0放行。
- `/Volumes/RC500/dev/safarier/Tests/SafarierAppTests/LegacySystemDragBoundaryTests.swift`：增加真实非持久WebKit的只读computed-style回归。未展示窗口、未合成输入或设置选择。修前实际text而失败，修后none且初始snapshot为0而通过。

主agent复核把初稿anchor&&focus修成OR，防止拖出控件时漏计部分自定义区选中；未改生产输入。两阶段diff/冻结与真实RED/GREEN日志保留，没有改预期去迁就现状。

## 4. 反向负例证明没有“改测试换绿”

更严格private probe逐字同步当前root custom-pointer record行，Root fixture仅附加原只读观测；扣除观测可逆恢复Root，所有其它原case、动作与allPassed不变。

再复制该App，仅移除CSS前缀，重新签名后与修正版代码TEXT仍相同。该裸CSS反向负例：selectedLength=11，**custom_pointer_drag_buttons明确失败**，随后系统drag被拒绝，原allPassed=false、总16项报告；没有忽略失败或补发up/drop。因而新oracle比原来更严格，兼容样式修复不是隐藏系统drag或删原断言。

## 5. 原可见性诊断矩阵：九轮全通过

以下使用当前原生执行器、原fixture修复与当前严格oracle的安全观测副本；private callback维持后台systemDrag deny，外层tripwire保留。未调用旧run.py的LaunchServices/PID清理路径，也未伪称本机是隔离桌面。

| 状态 | 重复 | 每轮检查 | 失败 | custom选择长度 | deny/tripwire |
| --- | ---: | ---: | ---: | ---: | --- |
| background | 3 | 25 | 0 | 0 | 均未命中 |
| occluded | 3 | 25 | 0 | 0 | 均未命中 |
| hidden | 3 | 25 | 0 | 0 | 均未命中 |
| 合计 | **9** | **225通过** | **0** | **0** | **0** |

每轮均真实执行hover进出、点击/复击/checkbox、ASCII/中文/退格、password安全、range拖动、textarea选择、custom-pointer、按住/移动/释放、滚动、活动/临时查询恢复、cursor保护与原安全项；页面事件trusted等原条件保留。每轮snapshot PNG生成，主agent实际查看其中一份，文字、勾选、滑块和自定义控件呈现符合fixture状态；截图只含自有页面，不是桌面。

包括反向负例在内的10轮，每轮外部只读observer15秒/1500样本、NSApp始终nil，覆盖probe初始至最终时刻，schema全部通过。样本中14类×2状态计数均保持常量、cursor仅基线hash；原报告own activation=false、own global pointer events=0。这是本轮静默输入观测，**外部键盘事件为0，不能据此声称持续打字/IME不丢字**。记录源状态名不当作绝对硬件来源证明。

精确原件、失败、命令、退出码与归因在：

- `/Volumes/RC500/dev/safarier/.build/automation-page-drag-forensics-20261030/matrix-summary.json`
- `/Volumes/RC500/dev/safarier/.build/automation-page-drag-forensics-20261030/matrix/strict-bare-control/report.json`
- `/Volumes/RC500/dev/safarier/.build/automation-page-drag-forensics-20261030/matrix/strict-background-1/report.json`（其它state/round同名）
- `/Volumes/RC500/dev/safarier/.build/automation-page-drag-forensics-20261030/matrix/strict-background-1/page.png`

## 6. 原完整测试与保全

主agent另独立执行原完整XCTest三轮，不filter、不删断言，每轮**344 entries=341pass/3原条件skip/0fail**：WebKit77（skip2）、Network100、Core96、App71（skip1）。新增一项只读WebKit回归已实际执行；三个原skip仍未算通过。原native bridge脚本亦重复三轮，每轮93checks通过。只读日志helper的限额/权限/字段过滤/exclusive/symlink离线回归由主agent独立运行。

本轮没有修改任何生产Sources、Package、原NativeEvents、NativePageInput或shipping gates；不存在针对网页注入选区清理/DOM点击来补偿的实现。原计划追加本批事实；其余baseline、兄弟仓库dirty、缺失资源与工具路径按hash保全，无提交、推送、正常App安装或发布。均只运行持有句柄的自有诊断进程，父进程wait回收，不按名称清理他人进程。最终审计：`/Volumes/RC500/dev/safarier/.build/automation-page-drag-forensics-20261030/final-review.json`。

**阶段边界：原9×25原生诊断矩阵恢复，不代表正式产品G1–G5全部通过。** private background policy注入与component路径不是Factory/OwnedPage/Runner/AppleScript正式闭环；实际并行文字接收、修饰键、IME、正式recipient冷启动及完整UI逃逸/销毁回执仍需验收，门禁继续关闭。下一步应转向正式入口链路与这些缺口，而不是为本次夹具问题再改一套鼠标执行器。
