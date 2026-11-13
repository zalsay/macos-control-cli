# 持久环境 CLI 控制：实现追踪

目标：默认支持现有和新建 profile，不改变其持久数据、代理/订阅、机型或 SPI；旧 `allowsBackgroundAutomation` 字段不再作为授权位，也不批量改写旧记录。身份、原锁、profile 快照、唯一 Manager 和每代 45 秒 Binder 仍须验证；profile 删除撤销控制。

## 阶段一：新建受控 Runner

复用与交互 Runner 相同的 profile 准备、出站和 `DataStoreManager`。persistent 使用 profile UUID 对应的 `WKWebsiteDataStore`；`AutomationSnapshotStore` 仅管理控制截图。取消、过期、断连和 release 均不得删除网站数据，cleanup 回执仍只反映其原有的资源证明。

实现前检查实际受控 Runner 的绑定快照与传入 profile 完全一致，并验证代理与订阅引用的实际快照；不以默认直连或临时数据存储代替。代理跟随语言/时区触发的 Runner 重新启动会破坏原通道及进程身份，需要在受控启动路径中解决，不能绕过原绑定。

## 阶段二：已有交互 Runner 与重新接入

普通新版 Runner 由 Manager 启动时，预先建立并持有仅属于该 Runner 的认证注册通道和进程/原锁身份；控制租约与 Runner 生命周期分开。每次控制新建独立代次、token 和最多 45 秒 Binder，对 Manager、Runner、原锁、profile、窗口和调用方重新验证。上一代输入与回复队列未确认关闭时拒绝新代次；release 仅移交窗口及释放该代输入，保留 Runner 注册以便后续安全重握手。已有交互窗口在取消、过期或断连时仍属于用户，不因控制结束被关闭。

旧版已运行 Runner 没有这个端点，不能从 PID 或锁文件推断授权并补接；升级后由用户自行关闭、用新版重新打开一次。当前测试保护已有“视频号”窗口；真实持久 Cookie/localStorage 往返只在独立 fixture 和经协调的更新后进行。

以上为目标及约束，阶段未全部实现前不得声称普通 profile、代理或重接入已可用。
