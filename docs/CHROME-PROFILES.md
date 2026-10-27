# 指定现有Chrome profile（v0.3.2）

```sh
mcc chrome start --profile mcc --url https://creator.xiaohongshu.com/
```

`--profile`接受Chrome界面中的**显示名称**，精确匹配当前用户默认Chrome数据目录的注册profile。例如本机显示名`mcc`对应内部目录`Profile 2`，不会把名称直接当作路径，也不会硬编码这个映射。

## 可选默认值

复用原有配置入口，仅改mcc的`config.toml`，不修改Chrome设置或账号：

```sh
mcc --config chrome --profile mcc
mcc --config
mcc chrome start --url https://example.com/ # 使用配置默认值
mcc chrome start --profile OtherName       # 显式值覆盖默认值
mcc --config chrome --clear-profile
```

配置格式：

```toml
[chrome]
profile = "mcc"

[chrome.window]
position = "left"
height = "available"
max_width_px = 1600
```

默认配置不存在、CLI也不指定时，保持0.3.1原有Chrome新窗行为，不读取profile名称映射。命令行显式名称优先于配置；配置中的profile与`models.toml`模型profile是两个不同概念。本次升级不自动设置任何用户默认值。

## 路由与身份

- 只从当前用户默认的`~/Library/Application Support/Google/Chrome/Local State`提取名称和注册目录；32MiB有界读取，拒绝非普通文件、符号链接、其他用户文件。目录必须存在且属于当前用户，不允许路径穿越、访客或系统profile；重名不猜测。
- 指定profile时，通过Chrome标准profile-directory与明确的原用户数据根目录启动新窗口，不创建独立浏览器数据目录。指定目录消失时不让Chrome自动创建；目录设备/inode和名称映射在导航前后再次核对，不静默回退到默认账号。
- Chrome AppleScript的普通make-new-window不能指定profile。显式profile链路先打开当前任务私有frames目录的一次性静态HTML文件，无页面脚本或外部资源。Chrome156会忽略启动命令中的about:blank片段，因此不使用它来猜测目标。
- 用精确CGWindowID/PID/AX窗口自身的AXDocument识别标记；标记出现在旧窗、重名、无法验证时拒绝。仅移动该新窗，复用已有AX布局、A→B回读和只读AppleScript receipt映射，再导航到目标网址。不是按标题、front window或唯一新增差集猜测。
- 标记文件通过现有daemon/frames生命周期清理，成功、失败、helper取消/超时返回后都尝试删除；异常终止遗留文件在原有runtime启动清理流程中处理，不另建服务/CDP/DOM/JavaScript接口。标记路径只在内部helper协议中传递，不能通过客户端请求任意指定。
- 回执新增`profile:{name,directory,path}`，与原`connectionId/window/layout`并存。path是所选注册profile路径；实际路由使用Chrome的受支持参数，本机另通过Chrome自己的版本页确认实际Profile Path，不宣称对任意Chrome策略覆盖提供额外保证。

## 边界与安全

不同profile有各自的网站登录态。本功能不复制Cookie、密码或登录数据库，不自动登录、扫码或发布。`mcc` profile尚未登录网站时，应在该profile内按正常流程登录，不会借用其他账号的登录态。

仍要求原有屏幕录制/辅助功能及Chrome自动化授权。窗口必须新建、左侧全高并回读；最大原像素宽1600、高8192，JPEG<1MiB，不缩图。原有连接、焦点、暂停、首次输入倒计时与取消门禁不变，`USER_PAUSED`后不自动重试或重建runtime绕过。

未覆盖自定义Chrome用户数据根目录、同名显示名称的自动消歧、Chrome策略强制选择、所有物理多屏/Retina组合。本版不新增`--profile-directory`用户参数或profile创建功能。

验证与剩余限制见[v0.3.2验证](V032-VERIFICATION.md)。
