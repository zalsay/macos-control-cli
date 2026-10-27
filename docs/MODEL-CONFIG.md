# 通用 Decisions 模型配置（v0.3.0）

`mcc`、`desktop-control`、`copis-chrome` 共用配置，独立于各自 runtime。默认目录 `~/.config/mcc`；需要任务隔离时设置绝对路径 `MCC_CONFIG_DIR`。配置命令只操作本地文件，不启动 daemon、Chrome 或网络。

## 配置与命令

`models.toml`（目录0700、文件0600，必须属于当前用户；拒绝符号链接）：

```toml
default_model = "jev"

[models.jev]
url = "https://openrouter.ai/api/alpha/decisions"
api_key = "your-api-key"
model = "typesafe/jev-1.13"
```

推荐从宿主秘密管理器以 stdin 提供 key，勿写入对话或日志：

```sh
secret-provider-command | mcc --config set jev \
  --url https://openrouter.ai/api/alpha/decisions \
  --model typesafe/jev-1.13 --api-key-stdin
mcc --config default jev
mcc --config
mcc --config show jev
```

`secret-provider-command` 是宿主提供密钥的占位命令。stdin 允许末尾一个 LF/CRLF；key 为1–1024个ASCII非空白可见字符。不执行输入内容。也支持 `--api-key <key>`，但 argv、shell 历史或 Agent 工具记录可能暴露它。所有配置回执/API key 字段脱敏。多个命名 profile 使用相同格式，`default` 选择默认 profile；第一个 profile 自动成为默认。现有 profile 可只更新 `--model`；**改变 URL 必须显式重新提供 key**，不会跨端点沿用凭据。

URL 是完整 Decisions API 地址，按原路径 POST，不补 `/chat/completions` 或 `/decisions`。支持 HTTPS 以及仅用于开发的 HTTP loopback（localhost/127.0.0.1/::1）；拒绝 URL 用户名、密码、query、fragment。对外 HTTP 明文端点不允许。使用系统 TLS 信任链，不跟随重定向，不使用代理环境变量或 curlrc。只有协议兼容的 Decisions 服务可用；配置任意模型名不意味着支持普通聊天或视觉 API。

### 从旧配置迁移

v0.3.0 不再隐式读取进程 `JEV_API_KEY`/`OPENROUTER_API_KEY` 或工作目录 `.env`。用户已有 `.env` 不修改、不执行、不删除。由宿主安全读取需要的 key，再通过 `--api-key-stdin` 写入上述 profile；配置前检查 URL 是否属于这份 key 的提供方。不要直接 `source` 不受信任的 `.env`，也不要把 key 粘贴到聊天。

`click-target --jev-key` 仍可覆盖**已配置 profile 的本次 key**，不改变文件。缺少默认 profile 返回 `MODEL_NOT_CONFIGURED`。每次调用读取最新 URL/key/model，daemon 不缓存配置。配置更新采用私有临时文件+原子 rename；并发写通过 `config.lock` 拒绝，异常退出遗留锁须确认无其他写入者后手动清除。

CLI 在发送 key 前核对 daemon 精确版本和 `jev.protocol:"decisions-v1", dynamicEndpoint:true`，不匹配返回 `DAEMON_UPGRADE_REQUIRED`；只停止自己持有的旧 daemon，重新连接。RPC 同时携带本次 URL/key/model 以及协议标签，旧客户端不被默默映射到新端点。key 不发给 Swift、不放 curl argv、不写 daemon.log。

## 与 Jev 数据契约的关系

仍是 target +候选 ID/文字，返回 ID 后本地查同帧坐标、调用原点击。请求 `model` 和响应校验使用本次配置的模型名（允许同名 `-YYYYMMDD` 版本），不再固定 OpenRouter。隐私授权、阈值、输入门禁和 `effectVerified:false` 不变，见 [Jev 点击契约](JEV-CLICK-TARGET.md)。
