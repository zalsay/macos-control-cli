# Safarier AI 内测工作区迁移

内测构建（`SAFARIER_INTERNAL_TEST_APP` 和 `SAFARIER_BOUND_LOCAL_CANDIDATE`）默认使用 `~/Library/Application Support/Safarier AI`。如发现旧的 `Safarier Test`，新版会拒绝打开默认工作区；新旧目录同时存在时也不会选择或合并。迁移后若旧目录再次出现，新版下一次启动仍会拒绝打开默认工作区。`SAFARIER_HOME` 的现有覆盖行为不变，显式覆盖不会触发默认工作区迁移。

迁移前，由用户确认所有旧版 Manager、Runner 和 CLI 均已退出，并确保迁移后不再启动旧版。新程序无法自动证明旧进程静止，也无法阻止仍在运行或之后重启的旧版本；旧版可能重新创建旧目录或写入旧数据。迁移命令会检查旧工作区已存在的锁并拒绝被持有的锁，但这不能代替用户确认。若两个目录都已存在，先停止操作，保留两份数据并人工处理；不要让命令覆盖或合并它们。

确认上述条件后，使用明确指向新版内测 App 的 `sfa` 执行：

```sh
SF_APP="/path/to/Safarier AI.app" sfa workspace migrate --confirm-old-versions-stopped-and-will-not-reopen
```

命令仅迁移默认工作区；设置了非空 `SAFARIER_HOME` 时拒绝执行。它校验旧目录及锁目录的所有者、类型和权限，通过同一父目录下的无覆盖原子重命名迁移，不复制数据；任何错误均应保留现状并先查明原因。若进程在重命名前后中断，请检查旧、新目录状态：只有旧目录时重新确认条件后重试；只有新目录时从新版启动；两者都存在时保留两份并人工处理。若提示系统错误或目录安全检查失败，不要用符号链接绕过检查。

迁移保留原工作区的 profile ID 和代理引用。持久网站数据由 WebKit 以 profile ID 关联，代理凭据使用原 Keychain service 和代理 ID；这不保证网站会话或钥匙串在目标构建上可用。迁移后应实际验证网站登录、代理凭据和各 profile；本命令不会迁移或读取 Keychain/WebKit 数据。
