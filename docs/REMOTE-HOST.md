# 公网 WSS 远端 Host（0.3.4）

本页适用于0.3.4。代码/构建、TLS回环模拟与真实双机/公网验收分别记录在[V034验证记录](V034-VERIFICATION.md)，不以本机模拟成功代替真实部署验收。

## 运行方式和信任边界

```text
本地Mac Agent / mcc --remote
     │ WSS：证书链/IP或域名校验＋独立Bearer token
远端Mac mcc host（前台进程）
     │ 原Unix daemon / Service / Swift helper
远端Chrome/普通应用、截图/OCR、Jev和系统输入
```

本地不启动Chrome、Swift helper或桌面daemon，不读取本地模型key；仍有CLI、网络和下载图片的开销。远端占用远端Mac的物理桌面/鼠标键盘，必须有已登录的图形用户会话，不是headless浏览器服务。

Host token是该scope的桌面控制凭据，不能交给不可信者。远端模式不是macOS应用沙箱，也不把按键/输入文字限制等同于阻止已授权桌面操作读取页面。公网部署仍应配置网络入口访问策略；不承诺抵御任意DDoS。

## 1. 在远端Mac准备原有权限与账号

先确认使用0.3.4完整包，CLI/helper来自同一版本：

```sh
mcc --version
mcc permissions
mcc permissions --request
```

权限申请只在Host本地由本人操作并确认。屏幕录制、辅助功能、Chrome自动化是不同权限；SSH启动进程不自动意味着获得图形用户的授权。远端网络API不提供permissions --request或解除暂停。

Chrome profile、窗口默认布局、models.toml全部在Host配置。不同Chrome profile不复制登录态：

```sh
mcc --config chrome --profile mcc
mcc --config window --max-width 1600
mcc --config show jev
# 使用模型前由Host本人配置URL/key/model；密钥推荐stdin，见MODEL-CONFIG.md。
mcc --config enable jev
```

模型被Host禁用时，远端click-target也拒绝；客户端不能提供jevKey/jevUrl等内部字段。模型开关不是全局急停，不追溯撤销已开始请求。

## 2. 无域名时生成私有CA / IP证书

在Host建立一个当前用户私有父目录，再使用不存在的新输出目录：

```sh
umask 077
mkdir -p "$HOME/.config/mcc"
chmod 700 "$HOME/.config/mcc"

mcc host tls init --ip <远端公网IP> \
  --output-dir "$HOME/.config/mcc/host-tls"
mcc host token init --output "$HOME/.config/mcc/host.token"
```

SAN可重复 `--ip` / `--dns`，合计最多8个；IP直接写证书IP SAN，域名写DNS SAN。不会自动探测公网IP，也不要求购买证书。生成目录拒绝覆盖已有目标，输出：

| 文件 | 用途 |
|---|---|
| host-ca.pem | CA公共证书，导出给客户端显式信任 |
| host-ca-key.pem | CA签发私钥；留在受保护位置，可由本人离线保存，不交给客户端 |
| host-cert.pem | Host服务证书，90天 |
| host-key.pem | Host服务私钥，仅Host读取，不交给客户端 |
| host.token（另行生成） | 独立256bit随机访问凭据，文件0600，不在日志/argv明文输出 |

CA证书365天，叶证书90天；初始化回执显示CA DER的SHA-256指纹和叶证书到期时间。Host运行只需服务证书/服务私钥，不需要CA签发私钥。首版没有ACME或自动续期，到期前在新目录生成并可信重新配对，不默默替换根CA。

已有公有CA服务证书也可显式加载。私有证书/访问token必须是当前用户的受保护普通文件；拒绝symlink、错误owner、错误权限及过大材料。不要把生产pem/key/token放进源码、聊天、录屏或分发包。

## 3. 可信分发公共CA和访问token

通过已核验SSH或可信离线方式取得 `host-ca.pem`，对照Host本地显示的指纹；不要从第一次不可信连接下载CA后直接信任。

客户端只需CA公共证书和单独的访问token，不需要Host私钥/CA签发私钥/Jev key。将token放在当前用户0700目录中的0600文件；不要把token内容放URL、shell参数、对话或环境回退。

`--ca-cert`仅影响本次mcc远端连接，不修改macOS系统钥匙串或Jev HTTPS信任。没有 `--insecure`、明文降级、自动redirect或隐式代理；证书链/身份/期限错误明确失败。IP或DNS身份改变应重新签发/配对，不能忽略错误。

## 4. 启动Host

```sh
mcc host start \
  --listen 0.0.0.0:8765 \
  --tls-cert "$HOME/.config/mcc/host-tls/host-cert.pem" \
  --tls-key "$HOME/.config/mcc/host-tls/host-key.pem" \
  --token-file "$HOME/.config/mcc/host.token"
```

Host为前台常驻进程；默认bind为127.0.0.1:8765，公网必须显式指定可达地址并由操作者设置网络/防火墙/路由。所有监听地址都要求TLS和token，不能裸露ws://。

Host启动入口固定scope：mcc和desktop-control为desktop，copis-chrome为chrome；客户端scope不匹配拒绝，不静默提升权限。一个Host同时一个控制会话，一个活动动作；其他会话不能接管既有connectionId或frameId。Host不会为了取得控制断开他人的本地连接、kill他人daemon或重建helper绕过暂停。

可选 `--state-dir <绝对私有目录>` 指定Host状态位置；不提供时在MCC_CONFIG_DIR（默认~/.config/mcc）下使用scope隔离的remote-host目录。不要在Host运行时删除恢复记录或更换状态目录规避保护。

## 5. 本地Agent调用

以下每次均显式指定remote，绝不因为存在配置就隐式改变原本地命令目标：

```sh
mcc --remote wss://<远端公网IP>:8765/mcc/v1 \
  --ca-cert /absolute/private/host-ca.pem \
  --token-file /absolute/private/host.token \
  chrome start --profile mcc

mcc --remote wss://<远端公网IP>:8765/mcc/v1 \
  --ca-cert /absolute/private/host-ca.pem \
  --token-file /absolute/private/host.token \
  observe --connection <上一步connectionId> --out /absolute/local/frame.jpg

mcc --remote wss://<远端公网IP>:8765/mcc/v1 \
  --ca-cert /absolute/private/host-ca.pem \
  --token-file /absolute/private/host.token \
  click-target --connection <connectionId> --target 保存
```

- CA/token参数都是客户端本地文件路径；Chrome profile/模型/窗口配置由Host读取。
- `/mcc/v1`为固定WS路径，省略路径时客户端可规范化；userinfo/query/fragment、其他路径或非WSS拒绝。
- 客户端用私有会话缓存和文件锁在独立CLI调用间保持session/boot/单调序号；可用 `--remote-state-dir <绝对私有目录>` 隔离客户端任务。并行写同一控制会话返回BUSY，不把输入排队。
- 远端网络/CA/token/版本/协议错误不回退本地，不启动本地helper，也不自动重试改变桌面的请求。
- observe通过有界二进制块取回原图，返回实际本地imagePath；--out只在客户端解释并拒绝覆盖。JPEG<1MiB、宽<=1600/高<=8192，不缩放。默认只保留最近32个登记的自动图片；显式--out不自动删除。遇用户替换/修改的文件不扫删。进程在创建自动图与登记身份之间被SIGKILL/断电的极端窗口可能留下未登记文件，为保护未知用户文件不按后缀扫描删除；32图上限针对已登记缓存，不是任意崩溃下的全磁盘配额。
- click-target内部截图/OCR/Jev都在Host，继续只发送target和候选ID/文字给配置模型，选出ID后查同帧坐标调用原点击；没有新增OCR复核，也不会默认下载内部截图。
- sent:true/click_sent只表示投递，effectVerified:false不变；业务完成仍需观察后置状态。

## 6. 暂停、断线和本地恢复

正常命令在完整回执/图片后确认ACK，再关闭本次WS；保留桌面控制连接，下一条CLI可以继续。不同于disconnect，也不重启helper。

原有人工接管、失焦、窗口变化、暂停、首次3秒倒计时和取消门禁保留。活动请求最多15秒无法确认心跳、超时、回执/ACK丢失或控制会话300秒空闲后，禁止新输入，并要求原生保持暂停ACK。取消未确认不能报告已安全停止。网络不是瞬间感知，只有ACK后才承诺旧请求不能继续投递。

投递结果不确定时返回对应错误和requestId，不自动重放。已有回执可通过只读query协议查询；查询不是重新执行。重连/清客户端缓存/换session/更换scope不能自动解除USER_PAUSED。

有原控制条时，由远端本人点击继续，保留原lease并等待原3秒倒计时，再发送新请求。没有可用控制条或Host重启/崩溃留下恢复记录时，先停止前台Host并保留其状态目录/原daemon，再由Host本人明确执行（运行中的Host持有状态锁）：

```sh
mcc host recover
# 指定过Host状态目录时需一致：
mcc host recover --state-dir /absolute/private/host-state
```

此命令不是WS端点。恢复过程先核对原owner/daemon/helper身份与停止状态，不能凭无主PID误杀他人进程；原helper仍存活或状态无法证明安全时保守拒绝，不悄悄创建新helper。正常停止Host也只清理本进程拥有资源，不关闭Chrome或他人daemon。原daemon会核对Host的Unix peer PID、UID和启动时间；Host崩溃或进程身份失效也会由daemon主动取消当前请求并保持暂停，而不是等待新客户端接管。

## 7. 文件与管理接口

默认远端select-file拒绝。Host本人显式设置允许根时才开放，例如：

```sh
mcc host start ... --files-root /absolute/host/uploads
```

之后select-file的path始终属于Host，且必须解析在允许根内，不能借symlink逃逸。它不会上传客户端本地文件。canonical-root检查不是文件系统沙箱；本地同权限进程在检查与原生文件选择之间并发替换路径仍存在TOCTOU边界，不应把允许根放在不可信进程可写的位置。图片下载只限会话注册帧，不是任意Host路径读取。

远端不提供：--config、--jev-key、Host/daemon生命周期、permissions --request、恢复暂停、shell或通用文件管理。初始化、模型配置、token轮换和恢复都在Host本地明确操作。

## 8. 公网资源限制与轮换

默认：握手5秒，头8KiB，认证前连接8，认证后连接4，一个活动动作；控制JSON与WS帧64KiB，有界分片/写缓冲；禁压缩和未masked客户端帧；有界IP/全局认证失败预算和请求速率。浏览器Origin存在即拒绝，首版不提供浏览器页面控制台或Cookie登录。

证书/token启动时加载，首版不热重载。轮换需按暂停/停止流程由Host本人操作、换受保护文件并重启；旧boot/session不自动变成新控制身份。Host本地恢复并重启后，旧客户端缓存会明确报RECOVERY_REQUIRED；操作者确认新Host身份后可选择新的--remote-state-dir重新建立会话，不把清客户端缓存当作解除Host暂停的方法。保留恢复记录，在必要时完成本地恢复后重新配对。不要假设修改token文件就立即撤销所有现有连接。

## 9. 协议与验收状态

WS子协议mcc.remote.v1，外层remoteProtocol=1；握手报告精确MCC版本、scope、boot、能力。认证、版本、大小、字段白名单和归属都先于操作。内部daemon所有者capability、原生pause参数及Jev参数不接受来自网络对端。

协议顺序为Hello→session确认→RemoteEnvelope→result/可选manifest+二进制→ACK→acked→close；只有原请求的id/sequence匹配才可确认。原请求按digest匹配已有回执，旧序号/淘汰回执拒绝，不作为新输入。

验证必须分层报告：纯状态/证书单测；本机真实TLS loopback+fake native/Decisions；双Mac桌面；受控公网。当前层级及具体命令以[V034验证记录](V034-VERIFICATION.md)为准。没有第二台Mac或可控公网地址时，不以loopback成功宣称双机/公网验收。
