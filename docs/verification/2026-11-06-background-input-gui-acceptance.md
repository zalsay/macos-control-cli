# 2026-11-06 后台键鼠固定 fixture GUI 记录

## 范围与候选

本记录仅覆盖当前源码构建的 legacy candidate 在固定 fixture 上各一次 pointer、form-a，及这两次运行的有限用户观察；不扩展至长期、任意站点或任意文本、IME、完整 G1/G5 或 shipping 验收。wheel 仍 **denied**。main 已独立核验源码冻结、签名、原始日志和两张实际图片；最终审阅记录见本 stage 的 main-final-review.json。

App 的 101 项输入与 host 的 8 项输入各自构建前后一致；main 核验 367 项物化基线、legacy 的严格 19/8 namespace、9 项 artifact pin、主 App 和 Runner 双层 strict 签名及实际 sender 身份。observer 未进入 legacy。新 0700 独占 root 实际 device `16777233`、inode `139982146`、uid `501`；旧 root receipt 的 device 与当前状态不符，未修改旧 receipt 或旧 root。构建、源快照、root 与主审证据见 `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/gui-background-acceptance-20261106-001/preparation.json`、`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/gui-background-acceptance-20261106-001/runtime-root.json` 和 `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/gui-background-acceptance-20261106-001/main-artifact-review.json`。

## 两次运行与清理

时间为北京时间（Asia/Shanghai），各执行一次，outer/host 均退出 0；原 AppleScript/Binder 路径先后完成 capabilities、open、getState，随后执行固定动作和 close。精确 argv、环境、原始 stdout、Manager/Runner 日志与截图路径见 `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/gui-background-acceptance-20261106-001/execution-evidence.json`；外层记录为 `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/gui-background-acceptance-20261106-001/pointer-outer.json` 和 `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/gui-background-acceptance-20261106-001/form-a-outer.json`。

- **Pointer**：09:18:55.038712–09:19:14.969681，native sequence 1–5，buttons `0/0/1/1/0`，覆盖 hover、移动、按下、按住移动和释放。main 核图确认 hover 绿色；截图在 held move **之前**，不能证明之后的 DOM drag/drop。图片 `/Users/yingzhang/safarier-bound-accept-20261106-f027e773485b4b3ea8aa92b97d98bb9c/gui-pointer-20261106-001/results/hover.png`，SHA-256 `e1cc78d11e506fc02921aa8d2d9f6ede43c952a62daaa99b7637eed8d2eb5e54`。
- **Form-a**：09:19:53.894756–09:20:13.761233，native sequence 1–7，buttons 均为 0。固定步骤与 `FORM_DIAG`：

| 步骤 | valueCode | selection 起止 | trusted 计数变化 |
| --- | --- | --- | --- |
| clickButton | 0 | 0/0 | button 1 |
| clickText | 0 | 0/0 | focus 2 |
| insertASCII `native-123` | 1 | 10/10 | input 1 |
| backspace | 2 | 9/9 | input 2，down/up 1/1 |
| left | 2 | 8/8 | down/up 2/2 |
| right | 2 | 9/9 | down/up 3/3 |
| insertChinese `中文` | 3 | 11/11 | input 3 |

main 核图确认最终显示 `native-12中文`，caret 在末尾；图片 `/Users/yingzhang/safarier-bound-accept-20261106-f027e773485b4b3ea8aa92b97d98bb9c/gui-form-a-20261106-001/results/form.png`，SHA-256 `0ddc167072c4466a3ed0970b1e313731db0a05e105a1f2322683b7a9a7439442`。以上是固定输入及效果证据，native key 回执不是独立 key queue ACK。

Pointer 和 form-a 的 Runner 均记录 `destroyed=true`、`storeCleaned=true`、`removedFiles=1`、`retainedFiles=0`、`directoryRemoved=true`；两次 artifact base 事后为空。Manager 分别在 886 ms、825 ms 接受同 session cleanup proof，最终 receipt 均为 `cleaned=true`、`terminatedOwnedRunner=true`。host 随后记录 owned Manager 退出 status 15；**进程退出不替代真实 page/store cleanup proof**。

## 本轮用户反馈

用户针对 09:18:55–09:19:14 和 09:19:53–09:20:13 两段时间是否在其他 App 操作键鼠、是否出现光标跳动、焦点变化、误输入或中断，原话回复：“当时在操作，未发现干扰”。此反馈仅对应这两轮用户实际操作的有限主观观察，不继承旧轮反馈，也不扩大为长期或所有干扰情形通过。原始反馈收据 `/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/gui-background-acceptance-20261106-001/user-feedback-001.json`；执行当时的 `execution-evidence.json` 保留其当时尚未取得反馈的历史状态。
