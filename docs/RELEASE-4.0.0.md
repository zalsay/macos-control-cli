# 4.0.0

Ubuntu 22.04 Docker 桌面支持 Xvfb、Openbox、Firefox/X11、noVNC，以及从宿主 MCC 通过认证 WSS Host 调用容器内操作。

- Firefox 使用普通 profile 启动，登录数据保存在命名卷；移除 WebDriver/Marionette 启动与执行链，使用 X11 系统键鼠事件和既有鼠标轨迹算法。
- 支持远程截图/OCR、Jev 模型配置、宿主文件传输和原生文件选择框中的网页上传。
- 独立 Docker 桌面不因普通人工键鼠活动或空闲而触发 macOS 的自动暂停；明确暂停、取消、未知输入和恢复锁仍保留。
- Docker 的 `status` 返回已有 `connectionId`；持同一 Host token 的客户端可在空闲时接续原窗口，重新观察后输入。旧帧失效，旧回执保留只读查询但不能重放。macOS 的客户端归属规则不变。

源代码版本与 Git tag 均为 `4.0.0`，JSON 协议仍为 1。操作说明见 [Docker](MCC-DOCKER.md)、[mccd](MCCD-USAGE.md) 和 [Host](REMOTE-HOST.md)。

验证记录见 [Docker 验证](MCC-DOCKER-VALIDATION.md)。之前开发镜像已在 macOS OrbStack 的 Ubuntu 22.04 运行时完成宿主 MCC 直接调用；最新连接续用修复经三个定向单元测试及两个独立客户端的 observe/系统 hover 验证，窗口保持不变。本次版本收尾仅做相关定向检查，不运行全量回归。历史 AMD64 测试不代表最新连接修复已在 AMD64 验收；物理 Ubuntu、Windows/macOS Firefox 和公网入口未完成本版新增实测。

Git tag 不代表已生成或上传安装包，也不会自动更新既有安装或运行中的开发容器。
