# DSH 固定端口 61919（2026-11-16）

用户要求将 DSH 固定在当前使用的 61919，避免重启后改变 Web UI origin，使浏览器无法读到原主题配置。

## 修改

仅修改 `DshService.swift` 两条既有启动路径的参数，将 `--port 0` 改为 `--port 61919`，并同步注释。`restart()` 继续使用原有进程退出和启动流程。未新增代理、转发、存储迁移或生命周期机制。

## 定向测试

新增 `DshControlledServiceTests.testStartAndRestartUseFixedPort`，通过真实子进程记录收到的 argv，验证首次启动和重启都收到 `web --no-open --port 61919`。

- 修改前 RED：两次均收到 `--port 0`。
- 修改后 GREEN：1 项定向 XCTest 通过。
- 另一个尝试复用的既有重启测试出现了原有进程时序断言失败，因此保留该测试原样，采用上述独立的端口测试；未据此修改生命周期逻辑。
- 主 agent 审查修改；`git diff --check` 通过。未运行全量回归。
- 非受控启动分支仅做静态审查；真实 App 验证使用受控运行时分支。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  -Xcc -DSAFARIER_BOUND_LOCAL_CANDIDATE \
  -Xswiftc -DSAFARIER_BOUND_LOCAL_CANDIDATE \
  -Xswiftc -DSAFARIER_INTERNAL_TEST_APP \
  -Xswiftc -DSAFARIER_MANAGER_ROUTING_TESTS \
  -Xswiftc -DSAFARIER_CONTROL_TESTING \
  --filter DshControlledServiceTests/testStartAndRestartUseFixedPort
```

## 打包与真实 App 验证

已重新打包并安装至 `/Users/yingzhang/Applications/Safarier AI.app`，固定产物为 `dist/releases/Safarier AI.app`。源构建 `attempt-20261116-175638-dbf627765a32415ea4a85c754b7bdcbd`；源码清单 150 项与构建快照一致，安装及固定产物均通过 12 项 pin 和签名检查。DSH 保持 0.2.2-rc.2。

| 操作 | DSH PID | 监听地址 |
| --- | --- | --- |
| 安装后启动 | 60943 | 127.0.0.1:61919 |
| 应用内点击“重启服务” | 61552 | 127.0.0.1:61919 |

已确认旧 PID 退出，新 PID 为同一 Manager 的子进程，实际进程参数包含 `--port 61919`。应用内重启通过原生上下文菜单及 AXPress 执行；AXShowMenu 在本机返回 cannotComplete，未触发服务重启，该限制没有引入生产代码修改。

仅比较 `http://127.0.0.1:61919` 下 `codex-ui.theme.option` 的值指纹；安装后启动及应用内重启后均与操作前一致。未改动主题值，也未将存储值一致表述为人工目视主题验收。

## 数据与会话核对

- 配置、订阅、15 个原书签文件、3 个凭据文件字节一致。
- 恢复原 2 个运行浏览器及全部 4 个 daemon 路径。保存的标签数量一致（6 / 1 / 2）。
- “新媒体运营”及“本地inboard”的保存 URL 和选择状态一致。
- “My”中一个页面 URL 和选中标签与退出时快照不同；原始退出时会话在 `.build/dsh-fixed-port-20261116/data-after-quit/sessions/`。没有为通过核对而覆盖当前运行会话；变化来源未确认。
- 未提交或推送，保留此前未提交修改。

证据目录：`.build/dsh-fixed-port-20261116/`。主要文件：`port-red-focused.log`、`port-green.log`、`startup.json`、`restarted.json`、`startup-listen.txt`、`restarted-listen.txt`、`theme-startup.json`、`theme-restarted.json`、`metadata-preservation.json`、`session-preservation.json`、`final-review.json`。
