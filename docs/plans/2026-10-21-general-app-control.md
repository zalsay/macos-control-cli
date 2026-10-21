# 通用应用窗口控制演进

用户已批准从 Chrome 专用组件演进为通用 macOS 窗口控制。基于现有 Rust/Swift 链路，不增加新的截图或输入后端。

## 契约

- v0.2.0 新增 `desktop-control` 入口；`copis-chrome` 默认仍仅允许 Google Chrome。
- 通用模式默认 runtime `~/.copis/desktop-control-cli`，使用 `COPIS_DESKTOP_RUNTIME_DIR`；Chrome 保留原有 runtime/环境变量。
- CLI/daemon 信封增加模式标记；跨模式请求必须拒绝，不能误用或停止另一模式的后台。
- Swift helper 默认 Chrome，只在显式 `--desktop` 启动参数时启用通用模式；不允许单条 IPC 自行升级范围。
- 新命令 `apps`；`windows --app <bundleId>` 可筛选。只枚举有窗口的普通应用，排除 helper/后台系统进程。
- Window 元数据增加 bundleId/appName；通用连接固定窗口ID、PID、bundleId，并在所有观察/输入查询中复核。
- 原始截图/OCR、倒计时、用户暂停、精确焦点/几何/指针校验沿用原实现；不推测控件类型。
- 原生 select-file 暂只支持已验证的 Chrome 适配，其他应用明确返回不支持，不能扩张到任意对话框。
- 控制条在通用模式显示应用名与窗口标题；Chrome 旧标题和可访问性标识保持兼容。
- 先验证 Chrome、TextEdit、Finder；只对本次创建的测试窗口操作，不改用户文件、不发布内容。

## 执行顺序

1. Rust模式/协议/命令/进程与身份锁定：BDD失败→实现→测试。
2. Swift进程模式/应用目录/身份复核/采集：BDD失败→实现→测试。
3. 构建产物、双语文档与分发包 smoke 更新。
4. 独立源码测试、原生 smoke、构建、真实隔离窗口验证、简化审查。
5. 本地交付；用户明确要求后合并main并推送指定仓库，不擅自创建二进制 Release。

## 验收与限制

相同窗口内输入坐标仍为截图原像素。模式越权、bundle身份替换、未知窗口、未验证焦点必须拒绝。子窗口和保存框不会隐式扩大连接范围。真实测试不足时如实记录不支持/未验证，不能以sent:true作为业务成功。版本升级保留Chrome集成的module.json入口。

## 完成记录

通用和Chrome双入口、模式隔离、固定应用身份与双语文档已实现。91项Rust与原生smoke/应用范围BDD通过；TextEdit和Finder真实隔离输入验证通过。SCK遗留Chrome过滤及后台AX查询顺序已通过真实失败→修正→成功闭环处理。完整证据与限制见[验证记录](../GENERAL-APPS-VERIFICATION.md)。
