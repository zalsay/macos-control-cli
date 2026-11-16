# 显式导航改为提交后返回（2026-11-16）

## 行为与范围

- 在现有 registered 浏览器窗口中，`sfa control navigate` 调用 WebKit 接受加载请求后返回 `navigationSubmitted: true`、`effectVerified: false` 和新 `viewVersion`。不再等待 `didFinish`，不再执行原有导航完成等待及应用层 GET 重试循环。
- agent 用 `observe` 自行确认页面。加载中可以截图，也可以释放控制；旧截图 frame 在导航提交后失效。
- 后续网络加载失败只结束本次导航的内部状态，保留页面供观察和释放；不会再追发该命令的完成/失败回执。
- 身份、绑定、窗口及 URL 导航策略校验保留；没有认证成功的提交响应时，通道仍可能报错，包括 `INDETERMINATE_RESULT`。本次没有将传输故障伪装成成功。
- `click/Enter --wait-navigation` 的显式等待语义，以及非 registered 的内部测试页面路径保持原行为。

## 定向验证

已运行且通过 3 项测试，仅限本次协议、状态机及 broker 改动范围：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  -Xcc -DSAFARIER_BOUND_LOCAL_CANDIDATE \
  -Xswiftc -DSAFARIER_BOUND_LOCAL_CANDIDATE \
  -Xswiftc -DSAFARIER_INTERNAL_TEST_APP \
  -Xswiftc -DSAFARIER_MANAGER_ROUTING_TESTS \
  -Xswiftc -DSAFARIER_CONTROL_TESTING \
  --filter 'NavigationSubmissionTests|ControlNavigationSubmissionTests'
```

- RED：修改前，协议测试在解码 `navigationSubmitted` 时因 `INVALID_REQUEST` 失败。
- GREEN：提交结果编解码、状态机立即允许截图、拒绝把提交结果用于显式等待导航、拒绝错误版本、旧 frame 失效、broker 不把真实错误当成提交成功。
- 主 agent 完成代码审查；`git diff --check` 通过。没有运行全量回归。

## 已安装 App 的本地实测

使用新增 ephemeral 测试环境和 loopback HTTP 服务器；未导航或搜索用户的 Google 页面。

| 场景 | navigate | state / observe | release |
| --- | --- | --- | --- |
| 图片响应被人为挂起，页面仍在加载 | 3.568 秒，已发起 | 截图成功（3.598 秒） | 6.409 秒，四项均 true |
| 服务器主动断开主文档请求 | 3.558 秒，已发起 | 截图成功（3.432 秒） | 6.406 秒，四项均 true |

加载场景中，`state.loading` 为 `true`，截图已由主 agent 查看；截图可见本地测试页面正文。导航返回、截图和释放均发生在服务器放行图片之前。释放后再放行图片，原窗口正常完成加载。页面还执行了 `replaceState` / `pushState`，此过程没有使观察或释放失败。
失败场景中，WebKit 回调加载失败，`state.loading` 为 `false`，旧文档仍可截图，释放四项均 true。测试程序只提交一次该导航；服务器记录的多个 `/fail` 网络请求来自 WebKit 内部请求处理，不能据此声称整个浏览器网络层没有重试。

## 安装与数据保护

- 安装位置：`/Users/yingzhang/Applications/Safarier AI.app`。固定打包位置：`dist/releases/Safarier AI.app`。
- 本次源构建：`/Volumes/RC500/dev/safarier/.build/automation-bound-control-integration-20261104/formal-test-app-20261106-001/packaging/attempt-20261116-172011-83480d3d65304d30bde38fbeed9b0e05`。
- 当前源码清单 150 项与构建后快照一致；安装包与固定产物均通过 12 项 pin 和签名检查；DSH runtime 保持已审核的 0.2.2-rc.2。
- 配置、订阅、13 个书签文件、3 个凭据文件逐字节一致；原 3 个环境的已保存 URL 和选中标签一致（6 / 1 / 1 个标签）。恢复了两个原运行浏览器、Manager、DSH 入口及 4 个原 daemon 路径。
- 临时环境 UUID 从本次 CLI 创建回执取得，并在删除前与原始 UUID 清单比较；仅清理该新环境、其浏览器、测试 daemon 和 loopback 服务。
- 未提交或推送；保留此前未提交工作。

## 单独保留的连接问题

首次连接返回 `RUNNER_EXITED`（requestID `AE9BED68-9F7A-4A52-87B4-909102737FC0`），尚未发送导航。Runner 日志定位在 `initialize/mainBundle`，`collector_bundle_4`（`BB_CHANGED`），没有进入导航测试。
随后对当前安装包执行严格 codesign 验证及 12 次独立 bundle 重验均通过；只正常重启了新建测试浏览器，再连接后上述两轮通过。首轮拒绝的具体变化来源尚未确定，未因此放宽任何身份检查，也不据此宣称历史连接或间歇性超时已经解决。

证据目录：`.build/navigation-submission-20261116/`；主要文件为 `protocol-red.log`、`submission-final.log`、`runtime-summary.json`、`fixture-profile.log`、`loading-page.png`、`metadata-preservation.json`、`session-preservation.json`、`final-review.json`。
