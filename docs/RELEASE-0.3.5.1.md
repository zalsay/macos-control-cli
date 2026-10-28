# 0.3.5.1 帮助补丁

## 版本标识

- Git tag：`0.3.5.1`，新增标签，不覆盖 `0.3.5`。
- Cargo、Cargo.lock、功能包 manifest、CLI/daemon/Host 握手版本：`0.3.5+1`。Cargo 拒绝四段 `0.3.5.1`，因此使用合法的三段 SemVer 加构建元数据；不引入第二套显示版本或协议版本覆盖机制。
- Apple Silicon 包名：`copis-chrome-0.3.5+1-darwin-arm64`。

## 更新范围

复用原帮助生成入口，补齐 `mcc`、`desktop-control`、`copis-chrome` 的本机流程、模型配置、固定安装目录、图形授权归属、公网 WSS Host/client、证书/token 分发、参数顺序、两端路径、文件根限制、会话过期和本地恢复说明。

修正任务结束必须停止 daemon 的误导：先 disconnect，只结束自己任务创建的 daemon，不停止常驻 Host 或他人的会话。命令解析、模型调用、执行器、原生输入、权限、暂停、焦点及倒计时逻辑均未改变。新增帮助回归校验命令名、可解析示例及帮助请求无运行数据副作用。

## 构建元数据兼容修复

状态回执缓存的原版本白名单仅接受数字、点和短横线，会拒绝本补丁实际版本 `0.3.5+1`，在远端状态读取/回放时导致 `INVALID_ARGUMENT` 和连接关闭。本补丁只在原白名单中增加 `+`，继续限制非空、最多 32 字节，不接收空白或命令字符；不改变 Host/client 精确版本匹配，也不改变任何输入或暂停门禁。新增回归验证状态回执的 ACK/回放保留版本元数据，并继续拒绝超长、空白及注入内容。

## 构建及安装

```sh
bash build.sh
sh install.sh --package "$PWD/dist/copis-chrome-0.3.5+1-darwin-arm64"
mcc --version
mcc --help
```

默认真实运行目录继续为 `~/Applications/MCC/`，旧包归档不删除。版本和帮助查询不请求系统授权或启动桌面控制；实际控制的权限以系统针对当前进程的授权为准，固定路径不承诺任何升级都免授权。

远端 Host/client 仍要求**精确相同版本和入口模式**。只升级本机 mcc 不会升级远端 Host；仍在运行 `0.3.5` 的 Host 应继续使用保留的 `0.3.5` 客户端，不能因 SemVer 构建元数据相近就绕过原版本检查。

验证日志放在本地 ignored `target/v0351-release/`，不夹带到源码或分发包。Git tag/推送、构建/安装、运行验证分别以实际回执为准；打 tag 不等于创建 GitHub Release。
