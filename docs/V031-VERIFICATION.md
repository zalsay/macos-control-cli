# v0.3.1 授权入口与 Chrome 实机验证（2026-10-27）

## 本次修复

- 复用已有`permissions`和`permissions --request`。前者只读检查三项权限；后者在原生串行工作队列显式申请屏幕录制、辅助功能、Chrome Apple Events授权，Apple Events的askUserIfNeeded参数为true。普通Chrome启动仍只读检查，不自行弹框或点击允许。
- 新增`chromeAutomation`回执：target、requested、granted、status、osStatus。requested表示走申请路径，不等于强制弹框或已允许。Chrome未运行、已拒绝、尚待本人同意、未知状态均不冒充已授权。
- 旧daemon版本门禁、新授权回执缺失的helper升级门禁；权限查询原生EOF仍进入原有连接失效/清理路径，未跳过原有错误处理。
- 主agent实机发现并修正两项启动问题：Chrome脚本术语`tab`被输出成文字而非HT，改为tell块外明确构造character id 9，仍严格校验五字段receipt；窗口必须先定位顶边再设置满高，避免macOS按旧y把高度钳短。未放宽身份、几何或点击门禁。

## 测试

- Rust：`cargo test --locked --offline -- --test-threads=1`，152项通过，1项真实付费API测试默认忽略。本次未新增模型网络调用。
- `cargo clippy --all-targets --locked --offline -- -D warnings`、格式和diff空白检查通过。
- Native：全部BDD与172项无副作用JSONL smoke通过。包括申请true/查询false传递、授权状态映射、真实本地osascript管道HT格式、先位置后尺寸的系统钳制fake、位置失败不继续尺寸、USER_PAUSED/取消保留、原有窗口/焦点/输入/捕获回归。确定性测试不弹授权框、不创建Chrome窗口。
- 红/绿证据：旧permissions回执缺第三权限、Swift缺少共享申请入口、权限查询EOF不清除连接、缺少明确布局顺序测试均先失败后通过。实机receipt文本tab及AX/CG高度钳制也先复现，再修复重测。

## 真实运行结果

使用任务私有runtime，不动用户全局daemon：

1. 新版查询最初返回`requires_consent / osStatus:-1744 / requested:false`。
2. 实际执行`permissions --request`后返回`granted:true / osStatus:0 / requested:true`，3486ms。后续只读查询仍为granted，且requested:false。由用户本人决定系统授权，未点击允许或重置TCC。
3. 修复后Chrome启动成功，返回created:true、connected:true、原connect的connectionId，耗时1284ms；新窗ID1503，PID3928，bundle=com.google.Chrome。
4. 主屏可用宽3440、高1336原像素，scale=1；新窗bounds为x0/y30/width1600/height1335。高度有1原像素平台差异，在既定回读容差内；没有为测试扩大容差。
5. ScreenCaptureKit真实截图1600×1335，coordinateSpace=frame-pixels，imageTransform=crop-only；经本地图片检查，小红书已加载`/new/home`创作后台，沿用之前的登录态，没有重新扫码、发布或上传。有效OCR达到128项上限时仍正常返回，没有恢复截断拒绝。
6. 初始窗口ID107以及启动前已有窗口的PID/位置/尺寸未变。两个失败阶段产生的测试窗1364、1492保留，未猜测归属后自动关闭；最终成功窗也保留。
7. 断开连接并只停止本任务daemon，最终running:false、connected:false；未发送网站鼠标/键盘输入。浏览器与登录态不清理。

私有证据：`/tmp/mcc031-auth-00pn17hc/evidence/qa-summary.json`和本地图片；含账号的图片/原始OCR不进入分发包。

## 交付边界

本记录是提交前验收快照：验收时工作区位于`codex/jev-click-target`，基线HEAD为`d8165e19dbb4b79fc6332512755040ae8c3f54d4`。由主agent审查，不委托子代理review。验收保留0.3.0产物，不覆盖用户PATH中0.2.4安装。后续Git提交/推送状态以仓库引用为准；这份验收本身不代表已合并main、安装或发布Release。

真实GUI覆盖本机1x主屏；Retina/负坐标等有纯几何测试，不等于物理多显示器、其他macOS版本或Intel实机通过。既有管道清理时间断言的并行调度偶发问题未声称修复，本轮Rust全量按串行执行。
