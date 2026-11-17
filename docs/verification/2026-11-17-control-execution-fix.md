# registered control 执行契约修复

日期：2026-11-17。基于 [MCC 源码对齐](2026-11-17-mcc-execution-alignment.md) 实施；Terra 承担页面和生命周期修改，主 Agent 修改 broker/CLI、独立复核全部改动并执行联合定向验证。保留工作树中此前修复，不提交、不推送。

## 实际修改

- registered 浏览器保持 interactive 模式和原 BrowserWindowController navigation/UI delegate。删除 registered 专用导航 permit、重定向/同文档白名单及等待导航路径；页面不再因这些裁决撤销 Binder。fixture 专用路径仍独立存在。
- navigate 在原 WebView 接受 load 后返回 `navigationSubmitted:true, effectVerified:false`。普通输入返回 `sent:true, effectVerified:false`；兼容的 click/Enter `--wait-navigation` 只发送一次原生输入，不承诺发生导航，不等待网页效果。输入不再读取 DOM 判断元素类型。
- registered 不再锁定前后台、窗口几何、标签成员变化或人工鼠标开关；窗口仍可人工操作。绑定的仍是原页面，切换标签不会自动把连接改绑到新页面。真实接收者不存在、不可命中或键盘响应者不属于该页面时如实报错。
- SFR scoped mouse 调用及 button-query hook 恢复同步完成，registered 投递回执不再等待 WebContent mouse processing fence。释放实际补发需要的 mouseUp，验证恢复本地 keyWindow hook，恢复/核对人工交互；不等待网页 activity 回调。真实调用或 hook 恢复失败不伪造交还成功。
- 取消 registered 的90秒 generation、60秒空闲自动清理、代次剩余预算门禁；相关 Manager、Runner、Binder 和 replay 均已同步。取消256次操作/连接和4096代次总量拒绝，保留全部 request ID/epoch 防重复记录。去重元数据随请求量增长。
- broker 保留最近32帧，不因页面版本变化废弃旧帧或否定输入回执；observe 接受实际新 viewport。截图存储取消旧8次/寿命限制，轮换保留最近32张。未知帧、非法参数和实际存储错误仍返回错误。
- 未收到旧回执 ACK 不再阻止下一条显式命令；真实在途输入仍串行。release 可进入预留通道，Manager 阻止新输入并等待已接纳操作排空，再执行原有两阶段交还。按键 held 状态不再按固定时间关闭整个会话，release 实际松键后交还。
- URL 入口接受可解析的绝对 URL，取消 scheme/userinfo 白名单；HTTP(S) 的 host 结构和原始控制字符仍作参数格式校验。页面是否加载由浏览器处理，效果由 agent 判断。

## 主 Agent 复核中修正的跨层问题

导航不再预加文档版本后，上层与原生输入的版本约定已同步；截图回执不再要求完成时页面仍与拍摄前相同；release 跳过页面 viewport 准入；registered 保持 interactive，避免遗漏直接判断 executionPolicy 的浏览器功能；释放与 WebKit 页面处理通知解绑，并确认人工输入状态后才报告交还。

## 验证

日志目录：`.build/control-execution-fix-20261117/`。

- `main-targeted.log`：主 Agent 独立选择66项定向测试，65项通过、1项跳过、0失败。包含 Core 12项和 App 54项。跳过的是既有真实 socket peer 身份握手测试，XCTest 宿主未通过其真实身份门禁；不计为通过。
- 其中包含真实本地 WebView 的页面加载、meta refresh 重定向和 history back，以及实际 WKWebView activity 的本地 hook 恢复。WebView 会话使用测试注入，没有走完整签名 Binder attach。
- 覆盖旧帧复用、resize、提交回执、ACK 未回时继续请求、超过256次操作、260次连接/释放、4097个 epoch、重复 ID 不重放、超过原寿命/空闲期限、33张截图轮换、held 释放和在途输入排空。
- `default-build.log`：不带 candidate 测试宏的 `swift build --product Safarier` 通过；联合测试同时编译了 candidate/internal-test 路径。未运行全量回归。
- `broker-*-red.log` 保存旧帧、ACK、容量和释放准入的修前行为失败。Terra 的独立定向证据保存在 `terra-execution.log`、`terra-lifecycle.log`，与主验证重叠，不累加测试数量。

主验证命令：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  -Xswiftc -DSAFARIER_MANAGER_ROUTING_TESTS \
  -Xswiftc -DSAFARIER_CONTROL_TESTING \
  -Xswiftc -DSAFARIER_BOUND_LOCAL_CANDIDATE \
  -Xswiftc -DSAFARIER_INTERNAL_TEST_APP \
  -Xswiftc -DSAFARIER_REGISTERED_TAB_TESTS \
  -Xswiftc -DSAFARIER_NATIVE_INPUT_POLICY_TESTS \
  -Xcc -DSAFARIER_CONTROL_TESTING \
  -Xcc -DSAFARIER_BOUND_LOCAL_CANDIDATE \
  --filter 'ControlDocumentVersionTests|ControlNavigationSubmissionTests|ControlExecutionReceiptTests|ControlUncertaintyAdmissionTests|ControlDiagnosticCorrelationTests|ControlDisconnectAcknowledgementTests|ControlNavigationURLTests|RegisteredExecutionLifetimeTests|RegisteredManagerRoutingTests|RegisteredAutomaticCloseTests|RegisteredActivityReleaseTests|RegisteredPresentationLeaseTests|RegisteredWindowAdmissionTests|RegisteredTabObservationTests|InternalNavigationPolicyTests/testWebAndSubframeSchemes|AutomationProtocolTests|RegistrationEpochHistoryTests'
```

## 当前边界

Agent 开关、真实目标/响应者、selector/ABI、参数解析、request ID 防重及 OS/IPC 错误仍如实处理。单次操作/通信超时与通道失联仍可能结束连接；没有将投递未知改写成成功，也不自动重放。release 等待在途原生操作，超过实际操作/释放期限仍会报告失败。

本轮完成源码修复和上述本地验证，尚未重新打包、安装或重启 App，没有重跑用户 Test 环境的 Google 多步骤操作。当前安装包不会因源码修改自动更新；不能将本轮定向通过当成真实完整接管与站点验收通过。
