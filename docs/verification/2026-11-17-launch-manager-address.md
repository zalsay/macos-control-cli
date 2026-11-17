# sfa launch 权限阶段超时：Manager 寻址修复

## 故障证据

基线：`5455752`，`mcc-safarier`。

用户在 DSH 中执行无 URL 的 `sfa launch 9080635F-0A64-4ECC-9969-58C9618B5072`，返回：

```text
CONTROL_AE phase=permission osStatus=-1712 sent=false senderAudit=false
失败：unavailable
```

DSH 会话记录与系统 navigation trace 均显示，故障发生于发送启动请求之前的权限查询。
当前 Codex 宿主的安装版 `sfa authorize` 也在 5.405 秒返回 unavailable/-1712。
采样线程停在 `AEDeterminePermissionToAutomateTarget`。

`appleeventsd` 日志明确记录：查询 `sh.safarier.testing` 时，系统尝试向 PID 77387
发送 entitlement 消息并超时。77387 是正在运行的 sfa daemon；已核验的 Manager 是 69999。
两者使用同一包、同一可执行文件，原 `typeApplicationBundleID` 寻址不能区分它们。

只去掉权限预检的临时只读发送器仍在 send 阶段超时（15.624 秒），所以没有采用这个修改。
临时改用 Manager 的系统进程序列号后，同一个 capabilities 请求在 0.818 秒成功，
实际回执的 sender audit 核验通过，结果中的 managerPID 为 69999。

## 修改

在既有 ControlSupport/ControlAuthorization 路径上修复地址选择：

- 捕获原 Manager 签名、路径、出生时间时，同时前后核对其 canonical ProcessSerialNumber。
- 把该序列号加入 CSControlManager 身份比较。
- 权限预检、显式 authorize 与实际业务事件均使用该 Manager 的 `typeProcessSerialNumber` 地址。
- 有界权限等待异步复制固定的目标序列号，不在 worker 内再次按 bundle ID 查找目标。

未增加备用通道、自动重试或权限绕过；既有 Manager 身份复核、TCC、禁止弹窗发送标志、
请求关联和真实回执 sender audit 检查保留。GetProcessForPID 是系统已弃用但当前可用的
Process Manager API，用于获得一次进程启动对应的 canonical PSN；没有使用裸 PID 作为 AE 地址。

## 定向验证

仅运行本次修改范围的测试，无全量回归。

1. `scripts/test-control-manager-address.py`：9 项通过。覆盖发送、只读授权、显式授权、
   查询拒绝/超时、发送拒绝/超时、Manager 身份与序列号变化。真实运行描述符构造、
   签名捕获和 audit 校验；仅替换 OS 权限查询、发送与系统生成的回执属性边界。
   修前寻址用例返回 wrongTarget/-1712；修后正常回执可用，错误不被吞掉或重发。
2. Swift 筛选 `ControlAuthorizationTests|ControlBusinessPermissionTimeoutTests`：10 项通过。
   包括 5 秒查询期限、迟到结果、人工授权等待和发送预算边界。构建出现既有的其他文件
   Swift 并发警告；本次 C/地址修改没有新增编译警告。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 scripts/test-control-manager-address.py
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  -Xswiftc -DSAFARIER_BOUND_LOCAL_CANDIDATE \
  -Xswiftc -DSAFARIER_INTERNAL_TEST_APP \
  -Xswiftc -DSAFARIER_CONTROL_TESTING \
  -Xcc -DSAFARIER_BOUND_LOCAL_CANDIDATE \
  -Xcc -DSAFARIER_CONTROL_TESTING \
  --filter 'ControlAuthorizationTests|ControlBusinessPermissionTimeoutTests'
```

## 真实通道验证与边界

通过临时 C 发送器调用修复后的生产 C 实现，向原已安装 Manager 发送请求：

- 保留原权限预检的 capabilities 请求：1.011 秒，status 0、sent 1、audit 1。
- 修复后的只读 authorization：0.597 秒，status 0、target_changed 0，不申请授权。
- 无 URL 的 Test 专用环境启动：0.284 秒；真实 Manager 返回 interactiveLaunched，
  profileID `8D0DB3A8-F413-4C32-8685-FC769FC7669F`，原始请求 ID
  `8215BAA3-0BF7-4DFE-A69F-ECE3C0AA8B0C`。启动前列表为未运行，启动后为 running，
  新 Runner 为 Manager 的子进程。只发一次，没有追加导航、接管或页面操作。

验证时“新媒体运营”已显示 running，未再次启动；My 与现有 Manager/daemon 保留。
Test 专用环境启动后保留窗口。以上验证来自当前 Codex 宿主的原生发送器，
不是已安装 sfa 的复测，也不能代替 DSH 宿主的实际授权验收。

未打包、替换 App、重启 DSH 或推送本次源码。已安装 sfa 仍包含旧地址逻辑；
需要更新 App 后，在原 DSH 宿主复测 `authorize` 与无 URL 的 `launch`。

本地证据：`.build/launch-permission-20261117/` 中的 `appleevents-system.log`、
`query.sample.txt`、`address-red.log`、`address-green.log`、`swift-tests.log`、
`fixed-probe.json`、`fixed-authorize.json`、`fixed-launch-test.json` 与环境列表前后快照。
