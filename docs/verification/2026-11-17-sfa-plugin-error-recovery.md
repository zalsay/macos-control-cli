# DSH sfa 插件历史错误拦截修复

## 根因

报错 `Prior operation is indeterminate; preserve browser and seek manual recovery` 来自
`/Volumes/RC500/dev/loom-os/plugins/sfa-tool/index.js`，不是 Safarier 的 release 回执。
当前 DSH web profile 中 `@loom-os/dsh-sfa-tool` 链接到该目录。

会话 `session-c054d862-d326-4794-8d17-f4fd93aff31d` 的记录显示：

- seq 432/433 已连接 runtime `sfc-Egkhvl`、connection `FCFF6FAF-875C-4914-AB85-A2039E8A3341`。
- seq 747/748 的 `press Space` 返回 exit 1、空 stdout、`control: unavailable or invalid request`。
- 旧插件把这个参数错误保存为 `uncertain`，seq 909/910 的 release 被插件直接拒绝，未发给 CLI。

## 修改范围

修改 loom-os 的既有 sfa 插件、其定向测试与 README；未修改、构建或替换 Safarier App。

- 删除永久 uncertain 拦截和最新 frame 缓存拦截；原样返回 CLI 结果，页面效果由 agent observe 判断。
- 每个输入只发一次；失败不自动重放，也不阻止后续显式命令。
- 插件重新加载后，从当前会话已完成的 sfa 记录恢复 runtime/connection；未完成调用不造成永久锁死。
- 保留既有参数验证、会话权限和并发串行化。
- release 回执完整后才停止 daemon；停止失败单独返回，之后显式 release 只重试 daemon 清理。
- 历史空结果不会使恢复报错；后续清理成功不会附带旧 stopError。

## 验证

仅运行修改范围内的三个插件测试文件：21 项通过，0 失败，未运行全量回归。
复核发现的历史 null 与 stale stopError 用例先失败，再修复通过。

```sh
node --test plugins/sfa-tool/test.mjs plugins/sfa-tool/test-extra.mjs plugins/sfa-tool/test-recovery.mjs
```

另以真实会话日志作为新插件输入，通过实际安装的 `~/.local/bin/sfa` 执行一次只读 state：
成功恢复原 connection，654 ms 返回 exit 0、status ok、sessionState ready，页面仍为小红书创作学院。
验证适配器只允许 state；没有重连、导航、输入、release 或 daemon stop。

本地证据位于 `.build/sfa-plugin-fix-20261117/`：
`final-tests.log`、`live-recovered-state.json`；故障调用链在
`.build/indeterminate-release-20261117/plugin-call-chain.json`。

## 生效边界

以上是真实日志恢复及插件到 CLI 的集成验证，未证明正在运行的 DSH Host 已加载新模块。
DSH 的官方 `@deepseek-ai/dsh-hmr` 文档说明，默认 `root: []` 不监听源码；
插件管理或 profile recomposition 可替换变更的链接模块，重启也会重新加载。
本轮没有触发 profile 重组、重启 DSH 或重新打包 App；当前会话还需重载插件后复测 release。
PageUp/PageDown 的先前源码改动也未因本次修复而安装，Space 支持没有变化。
