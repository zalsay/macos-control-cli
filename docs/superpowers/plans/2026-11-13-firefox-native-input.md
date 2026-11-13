# Docker Firefox 原生输入迁移计划

**Goal:** 按用户澄清的要求停用 Docker WebDriver，普通启动官方 Firefox，复用 X11 系统输入和既有鼠标曲线。

**Architecture:** CLI → daemon → Service → Native helper 保留。Firefox 生命周期改为直接持有普通子进程和 profile 锁；截图使用现有 X11 原像素窗口截图，动作编译结果交给现有 XTEST 注入接口。明确以 `firefox-x11` 标识新后端，更新远端能力，禁止自动回退。

**Constraints:** 主 agent 独立实施和代码审查；保留所有并行修改。不处理验证码、不伪造网页属性、不注入脚本。保留暂停/epoch/owner/焦点/窗口身份与均衡释放；原生窗口坐标包含浏览器工具栏。系统输入必须支持原有网页 Unicode 功能。

- [x] 生命周期：先验证无需 geckodriver 即能普通启动、profile 排斥及退出回收；复用原有私有 profile 校验。
- [x] 原生执行：扩展现有 X11 注入，复用完整计划预校验与曲线；检查物理光标、按键状态和人工接管；保持 Unicode。
- [x] 集成：同步 Service、CLI 帮助、Host 能力、回执、Docker 安装与文档；重写实际桌面验收中的内容区坐标依赖。
- [x] 验收：Rust 回归、Linux 实测、Firefox/noVNC/WSS/持久化、故障与暂停；主 agent 审查后保留分支，不提交或推送。

验收结果：完整 Rust 回归 378 通过；Linux 单元 121 通过，X11 live 1 通过；ARM64/AMD64 桌面与 WSS 均通过，ARM64 容器重启持久化通过。主 agent 完成审查并更新默认桌面，保留原 profile/密码卷。详情见 [验收记录](../../MCC-DOCKER-VALIDATION.md)。
