# 0.3.5 固定目录与原生helper改名验证

基线为0.3.4开发分支提交 `551dc550bd04b601cdc563326094e3584e8384f4`。本记录描述软件与本机验证，远端实际部署状态以对应Git提交及受保护部署记录为准，不代表系统授权自动继承。

## 实现范围

- 默认完整运行目录固定为Finder可见的 `~/Applications/MCC/`，mcc和macos-chrome-helper均为普通文件；bin/mcc只链接到固定目录，不再链接版本归档。
- 原不可变版本归档保留，自定义prefix隔离、旧版迁移、重复安装、升级及回滚共用原POSIX安装器的检查/锁/暂存机制，没有新增启动包装进程或第二套输入执行器。
- helper名改为macos-chrome-helper，build、manifest、运行时相邻文件查找及当前说明/测试同步；旧包manifest的copis-chrome-helper仅用于归档兼容。既有CLI名称、COPIS_*环境变量及codesign identifier不改名。
- 配置、证书、token、模型key、Unix runtime与Host状态不搬到可见运行目录。窗口、焦点、暂停、取消、倒计时、原像素坐标和原点击链均未改变。

## 主agent review

实现与定向安装测试由Terra worker负责，main负责helper/version/runtime改动、文档、唯一code review、最终全量和部署。主审发现并修正了：显式prefix无HOME的兼容；bin链接rename成功但随后报错时的回滚；在读取manifest前拒绝FIFO/symlink。回滚只恢复本事务发布的链接inode，不覆盖未知替换；旧目录/备份仅在内容能对应受管理归档时清理。

main另恢复了安装测试末尾对真实新名helper的默认发现验证：不使用helper环境覆盖，通过实际进程路径和canonical路径校验，避免fake掩盖改名错误。

目录切换由锁、完整暂存和失败恢复保护，两次目录rename之间可能有短暂缺口；这是停机升级，不承诺热替换。若用户在事务期间并发替换/修改目录导致无法证明所有权，保留数据/备份并报错，不能声称所有任意崩溃都已自动回滚。

## 本机已执行

证据位于ignored `target/v035-verification/`，worker行为RED/GREEN位于 `target/v035-installer/`，均不打包或推送。

- Runtime helper默认名字回归先RED（返回旧名路径），改名后GREEN。
- 真正Rust1.89全量：**323 passed、0 failed、1 ignored**；忽略项仍为真实付费API用例。
- 全targets Clippy `-D warnings`、fmt/diff通过。
- 完整native-smoke通过：原门禁/布局/profile/readback等BDD及**186项无副作用JSONL**；未投递系统输入或请求权限。
- Release编译、代码签名和包结构/源码/文档链接/SHA256检查。
- 临时HOME/prefix安装测试覆盖默认/显式.local/custom prefix、普通固定目录和文件、空间/引号路径、无HOME、重复inode保持、旧0.3.4迁移、升级/回滚路径不变、旧归档不变、恶意link/FIFO/篡改、运行中进程拒绝、其他prefix不误判、两次目录切换及bin发布前/发布后故障恢复、锁、真实新名helper发现与最终running:false。

所有真实用户安装、旧分发包和私有配置在实施前记录哈希，提交/部署前重新核对；不改写已安装同版本来绕过保护。源代码/新归档扫描实际已配置secret值，不携带模型配置、生产pem/key/token、frames或runtime。

## 签名和授权边界

固定真实路径仅消除版本目录变化；当前ad-hoc签名的designated requirement包含代码hash，因此代码升级仍可能需要重新授权。不改TCC数据库，不弱化签名校验，不承诺永久免授权。首次迁移后应以Host本地permissions请求和实际TCC责任路径确认。

远端升级必须先明确停止本任务LaunchAgent/daemon，保留状态与凭据，再安装并修改原job的固定可见启动路径。新客户端必须与Host精确同版本；保留旧会话缓存，完成本地恢复/安全升级后明确重新配对新boot，不用清状态或新helper绕过暂停。
