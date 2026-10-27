# 授权入口修复（用户已确认）

范围：复用现有 `permissions` / `permissions --request`，不新增平行授权命令。普通查询与Chrome启动仍只读检查；仅显式`--request`传askUserIfNeeded=true，由本人确认系统弹窗。报告Chrome自动化的granted/status/osStatus/requested/target，不启动Chrome、不发送网站输入。Chrome未运行时明确报告target_not_running，不能把procNotFound当成已授权。

版本0.3.1，保留0.3.0产物与已有0.2.4安装。先补query/request布尔传递与OS状态映射测试，再抽取原有Apple Events查询供启动与权限入口共用；请求仍在native串行工作队列，不阻塞AppKit主线程。旧daemon或未提供新授权字段的helper不能冒充完整申请成功。

验证：Rust全套（串行）、Swift定向与native smoke、release/package/install临时目录；任务私有runtime读取并显式申请权限，授权后继续验证新Chrome窗身份、主屏左侧全高/原像素截图；只停止本任务daemon，不自动点允许、不重置TCC、不触碰发布或账号。code review仅主agent。
