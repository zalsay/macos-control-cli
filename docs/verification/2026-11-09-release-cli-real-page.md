# Release 优化内测候选：CLI 真实网页与交接

日期：2026-11-09。范围是本地 arm64、macOS 14+ 的 Release 优化 testing candidate，ad-hoc 签名、未公证；不是正式发布、安装或部署，也不改变普通 shipping 后台准入。

`build.py --variant testing --configuration release` 生成独立 stage `attempt-20261109-161303-5d600ab336df4463876fd4b09ba6db7e`。109 项源输入 before=after=current，9 项 artifact pin、namespace、metadata、资源及 Manager/Runner strict 签名经主独立核对。配置映射定向测试 4 项、既有 testing variant 测试 4 项通过；默认配置仍是 debug。App 和 ZIP 位于 `/Users/yingzhang/safarier-release-bc289c34eaac4ad280b641c61a033903/`，ZIP SHA-256 `56112669e43aed0805b77a8a709edee37cbf5fe2d88cdcda75610c3459d86201`；副本和解包九项 pin 匹配，strict 签名通过。CLI `control --help` exit 0。

## 真实网页与交接

原始证据：`.build/release-candidate-config-10a91bb4ba6b4b839629fc77953f0f3d/gui-release/evidence/`。UTC 08:25:37–08:26:03 单轮 Selenium 表单：原生 move、click、type 后 `typed.png` 显示 `Safarier test`；一次 Enter 回执 ok、viewVersion 3，`final.png` 显示 “Form submitted / Received!”；state 为 submitted-form、loading=false。主已独立核查步骤、截图和原 NAV_DIAG。

08:26:00–08:26:02 的 `release.stdout` 为 ok，目标与原 state 一致，`inputReleased`、`artifactsCleaned`、`browserRetained`、`manualInteractionEnabled` 均为 true；这是保留浏览器的交接，不是 disconnect 销毁证明。daemon stop ok、原持有进程退出 0，socket 和本轮 artifact 目录消失。08:26:03 的只读采样显示原 Runner 的完整窗口 1525 可见，1280×852；窗口号仅作归属观察。Manager 以 noop 后台路径启动，本轮不以此证明 Manager 窗口可见。

用户确认完整地址栏、工具栏窗口可手动继续浏览；并反馈美东 03:25:37–03:26:03 操作其他 App 未发现干扰，仅限该报告时段。该测试 profile 已交给用户，不得重新接管或自动关闭。此前 `home-text-003` 的 Enter `INDETERMINATE_RESULT` 未在本轮复现，根因仍未确定；不能倒推此前 cleanup false/true 为成功。
