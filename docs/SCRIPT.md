# MCC / Host JSON 多步脚本

`script` 将多个现有观察、输入操作按顺序执行。每个步骤的 `eb: true` 对应普通输入命令的 `--eb`；省略或 `false` 使用原输入方式。脚本只包含 JSON 操作，不执行 shell、JavaScript 或任意程序。

## 本机与远端

先用 `windows` / `connect` 或 `chrome start` 获得连接，再提交脚本。文件路径须为客户端本地绝对路径：

```sh
mcc script --connection <connectionId> --file /absolute/flow.json

mcc --remote wss://host.example:8765/mcc/v1 \
  --ca-cert /absolute/host-ca.pem --token-file /absolute/access.token \
  script --connection <connectionId> --file /absolute/flow.json
```

远端只发送一次脚本请求，由 Host 顺序执行全部步骤。客户端不启动本地 helper，不读取本地模型配置；涉及 `click-target` 时复用 Host 的模型配置。脚本的连接必须属于当前会话。`host start` 参数保持原用法，见 [Host 配置](REMOTE-HOST.md)。本机也支持 `desktop-control script`；`copis-chrome script` 保留原 Chrome scope 限制。

客户端与 Host 须使用包含该功能的匹配构建；Host 声明 `remote.script.v1` 能力，旧 Host 在执行前拒绝。相同版本号的旧本机 daemon 也会被 `scriptProtocol` 检查拦截。源码修改与构建不会自动更新安装或重启现有服务。

## JSON 格式

完整文件见 [espble-flow.json](examples/espble-flow.json)。请先按目标窗口截图修改示例中的坐标与文本：

```json
{
  "version": 1,
  "timeoutMs": 40000,
  "steps": [
    { "action": "observe" },
    { "action": "click", "x": 100, "y": 200, "eb": true },
    { "action": "wait", "ms": 500 },
    { "action": "type", "text": "Hello", "eb": true },
    { "action": "press", "key": "Enter" },
    { "action": "observe" }
  ]
}
```

| 字段 | 约定 |
| --- | --- |
| `version` | 必须为 `1` |
| `timeoutMs` | 可选，默认 `40000`，范围 `1–40000`，全部步骤共享投递时限 |
| `steps` | `1–64` 个步骤，整个文件最多 `32KiB` |
| `eb` | 可选布尔值，仅用于 `click`、`click-target`、`type`、`press`、`scroll` |

每个步骤使用现有请求字段：

| `action` | 主要字段 |
| --- | --- |
| `observe` | 无附加字段 |
| `click` | `x`、`y`，可选 `clickCount`、`eb` |
| `click-target` | `target`，可选 `eb`；从 Host 配置读取模型 |
| `type` | `text`，可选 `eb` |
| `press` | `key`，可选 `eb`；如 `Enter`、`Cmd+A`，沿用对应后端按键范围 |
| `scroll` | `x`、`y`、`deltaY`，可选 `eb`；正数向下，非零且在 `[-1200,1200]` 内 |
| `wait` | `ms` 为 `0–10000` 的整数，全脚本等待合计最多 `10000ms` |
| `move` / `hover` | `x`、`y`，可选 `durationMs`；仅受管理的 Firefox 系统输入连接 |
| `drag` | `fromX`、`fromY`、`toX`、`toY`，可选 `durationMs`；同上 |
| `actions` | 现有 `actions` 数组；同上 |

Firefox 扩展仍沿用现有 `button`、`modifiers` 与动作编译器，见 [Docker 命令](MCC-DOCKER.md)。脚本不能包含启动/连接/断开、文件上传/选择、配置、嵌套脚本；步骤内不能提供 `connectionId`、`frameId` 或模型密钥。全部步骤沿用外层连接与最近一次成功观察步骤的帧。

通常第一步写 `observe`；也可在外层添加 `--frame <frameId>`，使用当前连接仍保留的帧。`click-target` 自行观察后点击，成功后更新后续步骤使用的帧。输入后不会自动观察；页面变化时应显式插入 `observe`，`wait` 不保证页面加载完成。普通坐标输入必须有之前的观察帧或外层帧。

ESP 坐标同普通 MCC，使用**窗口完整截图的像素**，由原执行链转换。不能直接把独立命令 `mcc --eb click 52,54` 的屏幕百分比填入脚本。ESP 仍受单主屏、整数百分比近似、单击、ASCII 及每次输入最多 16 个固件命令等限制；Linux / Firefox 系统输入连接拒绝 ESP，详见 [ESP BLE](ESPBLE.md)。

## 执行、暂停与回执

先校验整个文件的格式、步骤与静态参数，以及连接后端是否支持对应步骤。动态的帧保留、窗口几何、焦点、权限及 BLE 数据包校验仍在每次执行时进行，某一步仍可能在前面步骤已完成后失败。脚本持有原连接执行上下文；每步及等待期间检查取消、暂停、恢复锁、输入 epoch 和共享时限。脚本内检测到暂停即停止，不自动接管继续。原生调用使用剩余时限；已在途的模型请求可能稍后返回，但时限后的原生输入会被拒绝。原生 helper 超时沿用原停止/恢复策略。

成功示例（只列出部分字段）：

```json
{
  "ok": true,
  "connectionId": "conn-id",
  "frameId": "frame-id",
  "totalSteps": 2,
  "completedSteps": 2,
  "steps": [
    { "index": 1, "action": "observe", "frameId": "frame-id" },
    { "index": 2, "action": "click", "frameId": "frame-id", "sent": true, "eb": true }
  ]
}
```

失败保留原 `error.code`，在 `error.receipt` 返回 `totalSteps`、`completedSteps`、从 1 开始的 `failedStep` 及已完成步骤摘要。预校验失败时 `completedSteps` 为 0，`failedStep` 可指向后面的无效步骤；整份 JSON 无效、能力协商或连接检查失败时可能没有进度回执。若取消恰好发生在最后一步已投递之后，错误回执可显示全部步骤已完成且没有 `failedStep`。底层投递不确定时保留 `nativeReceipt`。

失败或明确暂停即停止后续步骤，不自动重试、回滚或续跑；已投递的输入无法撤回。传输断线时仍需按原 Host 恢复流程处理。原请求重放只返回缓存摘要，不再次执行；重新提交整个文件是新的操作，可能重复之前已完成的输入，应先核验当前页面。

摘要不返回截图字节、图片路径、OCR、输入文字或模型密钥。脚本最后的 `frameId` 可供后续同连接请求使用，但仍受原最近 32 帧保留规则限制；读取图像时使用现有 `frame` 命令或重新 `observe`。`sent: true` 和步骤完成只确认执行器投递，不证明页面或登录等业务效果。

## 直接调用 Host

已有认证、会话和序号协议中的请求内容为：

```json
{
  "action": "script",
  "connectionId": "conn-id",
  "script": {
    "version": 1,
    "steps": [
      { "action": "observe" },
      { "action": "click", "x": 100, "y": 200, "eb": true }
    ]
  }
}
```

可在外层增加 `frameId`。该内容放入现有 WSS 请求封装，不新增无认证 HTTP 执行接口。
