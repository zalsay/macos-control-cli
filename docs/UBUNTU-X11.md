# Ubuntu 22.04：直接控制当前 GNOME Xorg 桌面

这是 `codex/ubuntu-x11` 开发分支中的原生 Linux 支持。MCC 接入当前登录用户已有的 X11 会话，不启动 Xvfb、Openbox、noVNC 或新的桌面，也不需要 Docker。原有 Docker 模式继续独立工作。

## 环境

- Ubuntu 22.04，登录界面选择 **Ubuntu on Xorg**，在该用户的桌面终端运行 `echo "$XDG_SESSION_TYPE"` 应返回 `x11`。
- 普通用户运行 MCC，禁止 `sudo mcc`；继承当前会话的 `DISPLAY`、`XAUTHORITY` 和 session D-Bus 环境。不要复制其他用户的 Xauthority 或使用 `xhost +`。
- 本地 X server 提供 XTEST、XInput 2.1+ 和 XRes 1.2。GNOME 使用 EWMH 窗口管理；SSH X11 转发、Wayland/XWayland 会话不在此版本范围内。
- Rust 1.89+ 用于源码构建；安装已构建包不需要 Rust。构建和运行依赖可在 Ubuntu 上安装：

```sh
sudo apt update
sudo apt install build-essential pkg-config ca-certificates python3 \
  libgtk-3-0 libdbus-glib-1-2 libasound2 libxt6 x11-utils \
  tesseract-ocr tesseract-ocr-eng tesseract-ocr-chi-sim
```

Firefox 使用 Mozilla 普通发行包或非 Snap 的原生安装。Ubuntu 默认的 Snap 启动脚本不适用。将 Mozilla 官方 Linux 包解压到自己选择的目录，例如 `~/Applications/firefox`，然后在启动 MCC 的终端设置：

```sh
export MCC_FIREFOX_BINARY="$HOME/Applications/firefox/firefox"
```

默认路径仍是 `/opt/firefox/firefox`。宿主模式要求实际的 ELF 可执行文件，不接受 Snap/Flatpak 路径或包装启动脚本；不会修改系统默认 Firefox，也不读取日常 Firefox 的默认 profile。

## 构建与安装

在本分支源码目录中执行：

```sh
./build.sh debug
# x86_64 使用 linux-x64，aarch64 使用 linux-arm64：
sh ./install.sh --package "$PWD/dist/mcc-4.0.0-linux-x64"
```

`./build.sh` 默认生成 release 包；构建只包含 `mcc` 和 `mcc-linux-helper`，默认 jobs=1。`MCC_BUILD_JOBS` 可显式指定并行度。功能包包含对应源码、文档、LICENSE、安装脚本和 SHA-256 归档校验文件。同版本输出目录已存在时先由操作者保留/移走旧产物，不自动覆盖。

安装路径为 `~/.local/lib/mcc-linux-x11/<version>/`，`~/.local/bin/mcc` 链接到该包的入口脚本。可用 `--prefix /absolute/path` 选择其他用户级目录。无关的已有 `mcc` 命令和同版本但内容不同的安装会被保留并报错。安装不会启动 daemon、Firefox 或任何桌面进程，也不自动修改 PATH。升级前先正常断开并结束自己旧版本的 daemon；不要结束其他任务。

入口自动设置 `MCC_LINUX_DESKTOP=1`，使用同包的 `libexec/mcc-linux-helper`，并为当前 DISPLAY 选择独立 runtime。它保留已有 `COPIS_DESKTOP_RUNTIME_DIR`、`COPIS_DESKTOP_HELPER` 显式配置。`MCC_DOCKER=1` 与宿主模式不能同时启用。

## 当前桌面操作

下面使用已安装入口，始终在实际返回的 ID 上继续操作：

```sh
~/.local/bin/mcc permissions
~/.local/bin/mcc firefox start --profile ubuntu --url https://example.com/

CONNECTION_ID='上一步实际返回的 connectionId'
~/.local/bin/mcc observe --connection "$CONNECTION_ID"

FRAME_ID='最近一次 observe 返回的 frameId'
~/.local/bin/mcc hover --connection "$CONNECTION_ID" --frame "$FRAME_ID" \
  --x 200 --y 200 --duration-ms 300
```

Firefox 使用普通进程和 X11 系统事件，无 WebDriver/Marionette。轨迹算法与 Docker 后端共用；`--x/--y` 是截图原始像素，不能使用浏览器 CSS 坐标。Jev、OCR、系统文件选择框和 Host 文件传输沿用已有调用链。模型配置见 [MODEL-CONFIG.md](MODEL-CONFIG.md)。

原生 profile 默认保存在 `~/.local/share/mcc/profiles/firefox/<name>`，可用 `MCC_FIREFOX_PROFILE_ROOT` 指定私有根目录。它独立于日常 Firefox 的默认 profile，同名会话受原有文件锁保护。

宿主 X11 截图是当前桌面的窗口区域裁剪：目标窗口（或经验证属于它的文件选择框）必须在前台，尽量完整可见且不被其他窗口遮挡；后台窗口返回 `WINDOW_NOT_FOREGROUND`。观察不自动抢焦点，也不还原被遮挡内容。原像素尺寸、JPEG 大小、窗口身份、标题、几何和帧校验继续生效。显示布局或缩放改变后重新观察；GNOME 多显示器与分数缩放尚待实机验收。

## 人工接管

- 首次输入前显示控制条并等待三秒倒计时；人工操作可以中止倒计时或正在执行的输入。
- 当前连接期间的人工键鼠活动，以及已开始控制后的失焦，会撤销输入许可。本机模式需本人通过控制条 Resume，或在没有远端 owner 时执行 `mcc control --command resume`，后续输入重新等待倒计时。
- Pause/Cancel、未知输入、显示连接丢失、传输暂停仍保留原有边界。软事件不能把明确停止降级为可自动恢复的暂停。
- 使用远程 Host 时，只有原 owner 的新输入可按既有规则恢复软暂停；明确停止仍需控制条人工继续。宿主模式不启用 Docker 的空闲跨客户端接续，idle/heartbeat 规则沿用普通 Host。
- 系统原生授权和密码提示仍由用户处理。

## 远程 Host

在当前登录的 Xorg 会话终端通过已安装的 `mcc` 启动 Host，按 [REMOTE-HOST.md](REMOTE-HOST.md) 初始化 TLS/token 并配置监听地址。MCC 在这个用户的真实桌面执行输入，客户端机器只收回执/截图；不要通过 root 系统服务另起桌面或绕过登录会话权限。

本版没有设置开机服务或登录自动启动。当前用户退出图形会话后，显示连接失效，旧连接不能继续使用；重新登录后建立新会话。Host 远程能力声明包含 Firefox X11/system-input，连接继续绑定原客户端状态目录。

## 验证边界

本机开发环境为 macOS，Linux 专用代码通过单进程 Linux 构建和隔离 X11 fixture 检查；fixture 的虚拟显示仅用于测试，不属于宿主运行方案。GNOME/Mutter 实机、物理 Ubuntu 主机、AMD64、本版新增的多屏/分数缩放与公网 Host 不据此宣称验收。定向检查结果见 [Ubuntu X11 验证记录](UBUNTU-X11-VALIDATION.md)。
