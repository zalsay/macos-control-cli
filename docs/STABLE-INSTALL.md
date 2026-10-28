# 固定可见运行目录（0.3.5）

## 布局

默认安装不需要sudo，不修改shell配置：

```text
~/Applications/MCC/
  mcc
  macos-chrome-helper
  desktop-control
  copis-chrome
  assets/
  module.json
  ...完整功能包与源码/文档
~/.local/lib/macos-control-cli/<version>/  # 不改写的版本归档
~/.local/bin/mcc                         # 指向 ~/Applications/MCC/mcc
```

Applications/MCC是真实目录，mcc和helper是真实文件，不能用current→版本目录的链接替代。系统实际执行和权限归属路径不再包含版本号。CLI保留旧兼容入口；COPIS_*运行目录/helper覆盖环境变量、协议和签名identifier不改名。只有新helper文件名改为macos-chrome-helper。

`sh install.sh` 默认及显式 `--prefix "$HOME/.local"` 使用上述布局。其他自定义prefix将实际运行目录放在 `<prefix>/Applications/MCC`，归档和bin仍位于prefix内部，便于独立安装及测试。安装前校验manifest、平台、签名与版本；不联网下载安装运行时。

## 升级和回滚

1. 先确认没有别人的控制会话。仅结束自己拥有的连接/daemon；Host由LaunchAgent托管时先bootout本任务job，避免KeepAlive重启旧Host。
2. 运行新版安装器，保留原版本完整归档；先暂存完整包，再受锁保护切换真实运行目录，最后发布bin入口。失败应恢复原目录；未知目录、符号链接、篡改内容或正在使用的目标不得被自动覆盖或终止。
3. 同版本相同内容重复安装保持现有文件，不用重装触发签名变化；同版本不同内容拒绝覆盖。
4. 使用固定mcc启动Host，保留原CA/token/model/runtime/state；不能删除恢复记录绕过暂停。必要时按原Host本地恢复流程处理，再重新配对新boot。
5. 需要回滚时，在停止自己进程后，用0.3.5及之后的安装器选择原完整旧包作为 `--package`；不手工覆盖单个CLI/helper。旧包manifest的copis-chrome-helper名称只为旧包兼容，新包仅发布macos-chrome-helper。即使回滚，实际执行仍使用同一固定目录。

活动目录由安装器管理，不要在其中编辑源码、添加用户文件或编译；开发请用Git工作区/独立源码副本。保留归档用于验证和回滚，不将实际执行重新指向归档。

## launchd和授权

用户级LaunchAgent的ProgramArguments[0]固定为实际可见路径，例如 `/Users/example/Applications/MCC/mcc`；helper保持同目录。MCC不新增第二个启动包装进程或另一套输入执行器。配置、日志与凭据仍在原私有目录，不搬到公开运行文件旁。

录屏系统归属应以当前TCC实际日志/系统设置显示为准。首次从旧版本路径迁移可能需要重新授权。路径固定只解决路径变化：当前默认ad-hoc签名的designated requirement包含code hash，不能承诺任何代码升级都免授权；没有为了免授权而弱化签名要求或修改TCC数据库。

权限申请只能在Host本地明确执行 `mcc permissions --request` 并由本人确认，不通过WSS代为开启。窗口、焦点、人工暂停、取消与原倒计时均不因安装路径或helper改名而放宽。
