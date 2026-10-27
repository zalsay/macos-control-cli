# v0.3.2 Chrome profile验证（2026-10-27）

基线：已推送的0.3.1标签/提交`a9d3927cdc1c0ed2d584b81b3184bdc9d9e0763b`；本轮在`codex/chrome-profile-v032`实现，未自动提交、推送、打标签或安装。0.3.1保持不动。全部code review由主agent执行；子代理只实现边界明确的Rust参数/配置部分。

## 实现范围

- `chrome start --profile <显示名称>`；可选默认值`--config chrome --profile <名称>`，`--clear-profile`清除。显式CLI优先，未指定/未配置保留0.3.1路径。配置只写mcc的config.toml，不修改Chrome设置，也没有自动更改用户当前默认值。
- 有界只读Chrome Local State，名称唯一且对应现存普通目录；拒绝重复/缺失/路径穿越/符号链接/其他所有者，启动前后核对目录设备/inode与名称映射，不创建profile或静默切到别的账号。只返回name/directory/path，不输出邮箱、Google账号ID、加密密钥等其他字段，不读Cookie/登录数据库。
- 显式profile由标准Chrome启动参数选择，使用原用户数据根目录。仅由精确CG/AX窗口自身的AXDocument匹配一次性标记，旧窗或重复标记拒绝；复用原AX几何设置和回读，A→B只读AppleScript receipt证明映射，再导航最终URL。普通路径仍为原AppleScript新建，不改原输入/焦点/倒计时/暂停/取消逻辑。
- 初始about:blank#nonce方案在Chrome156被丢为普通新标签页，实机按预期拒绝，未猜测窗口。修正为现有私有frames目录中的静态HTML标记，无页面脚本/外部资源，无新服务/CDP/DOM接口。内部路径不能由客户端任意指定；Rust复用原frames生命周期在helper返回成功或错误时清理。

## 测试

- `cargo test --locked --offline -- --test-threads=1`：164项通过，1项默认忽略的真实付费API测试。本轮未调用模型API。
- `cargo clippy --all-targets --locked --offline -- -D warnings`、格式和diff空白检查通过。
- Native全部BDD及186项无副作用JSONL检查通过，新增profile解析/重名/缺失/目录替换/恶意目录/FIFO/符号链接/有界元数据、启动argv、私有标记文件、旧窗/重复标记拒绝、协议类型和路径验证。普通启动、原有权限/输入/焦点/截图门禁继续回归。
- Rust配置/参数测试覆盖Unicode、默认与显式覆盖、清除、窗口设置保留、原有无profile请求形状、无daemon本地配置、profile回执不一致不得连接、标记文件清理。
- 部分全量测试曾在并发调度下触发既有Jev管道清理2秒时限（2.166秒）；本轮最终全量按串行执行通过。未修改或宣称修复该旧时序问题。

## 实机证据

只使用本任务私有runtime与mcc接口：

1. `__mcc_032_missing__` 返回PROFILE_NOT_FOUND，窗口列表完全未变，没有新建profile或回退。
2. 本机已有显示名称mcc，注册目录Profile 2。修正后`chrome start --profile mcc`成功，返回原connect合同和profile元数据，1953ms；新窗ID1901/PID46560。启动前已有窗口位置/尺寸未变。
3. 新窗x0/y30，1600×1335原像素，主屏scale=1，可用高度1336，保留原有1像素回读容差，没有扩大容差或缩图。标记文件剩余0。
4. 通过原有mcc.press/type输入链导航chrome://version，包含原有首次输入倒计时。当前窗口自己的“个人资料路径”显示`/Users/yingzhang/Library/Application Support/Google/Chrome/Profile 2`；本地截图人工检查与OCR均确认。不是只检查请求参数或命令行字段。
5. 已有连接时重复chrome start返回CONNECTION_BUSY，无额外启动。没有访问目标业务网站、读取Cookie、复制登录态、登录/发布/上传；不假定mcc继承另一个profile的网站登录。
6. 后续还原空白页时返回FOCUS_LOST/reason=USER_PAUSED，停止后续输入，没有重试或重建runtime绕过。保留版本页。断开并只停止本任务daemon，最终running:false、connected:false；未强制关闭浏览器窗口。初始失败测试的新标签页ID1812也保留。

私有证据：`/tmp/mcc032-profile-qa-ewkog9sr/evidence/qa-summary.json`与版本页图片/原始JSON，均不进入分发包。没有为了测试修改用户Chrome Local State或profile名称。

## 边界

真实GUI仅覆盖本机macOS26.6.2、Chrome156.0.8078.48、arm64、1x及默认Chrome数据根。物理Retina/多屏、其他Chrome/系统版本、自定义user-data-dir、Chrome管理策略覆盖等未作实机承诺。profile路由依赖Chrome受支持的启动参数与本次唯一窗口绑定，不新增浏览器内部特权接口。

本版的打包与临时安装检查仍按原脚本执行；不会覆盖现有安装，不将未提交工作当成GitHub交付，也不会自动移动已发布0.3.1标签。
