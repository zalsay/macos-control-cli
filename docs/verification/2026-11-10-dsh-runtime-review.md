# Safarier DSH 独立运行时：离线阶段记录

## 当前结果

本阶段未将 DSH 集成进既有 CLI 控制应用，也未安装或发布新版本。用户确认的目标包括同时保留新 UI、DSH、CLI 身份和清理门禁，以及 macOS 自动化用途说明；目前仍有生产接入工作。

- `scripts/build-app.sh` 和 CLI 候选构建的 Manager metadata 含 `NSAppleEventsUsageDescription`。系统授权及其责任宿主尚未实测。
- `scripts/dsh-runtime/prepare.py` 构建仅供离线审核的 DSH/Node 镜像和逐文件 manifest。`verify.py` 要求外部明确传入预期摘要，不将镜像自己的 review.json 当信任根。两个工具仅适合离线候选，不是生产 verifier 或运行期租约。
- 主代理执行 12 项工具测试通过，并用外部指定的摘要重新校验真实镜像：75,721 项，13 个符号链接。当前候选 image SHA-256 `8a4c22bb334a3c307f8494cda029b80cd6a49545789e5e6087b878eef464baeb`，manifest SHA-256 `34e57a58a7674ebe656b249ab9f3bd2ca0cef45bdb9eacbec88592a8a0ec57de`；这些值只是候选，还未固定到可信应用中。
- Node 24.19.0 的签名和来源证据及隔离 DSH Web 启动记录见 `.build/dsh-control-integration-review/node24-evidence.md`；仅验证私有空数据目录启动、loopback 监听和未认证 HTTP 401，不代表完整 UI/控制/权限验收。

## 未解决的执行期一致性

用户私有目录可防其他用户的一般写入，但同 UID 可修改或替换其中的文件。Node 会在启动后继续加载 JS 和原生模块。只读挂载不会阻止修改镜像 backing 文件；在本机尝试以继承的 `/dev/fd/N` 作为 hdiutil 镜像输入返回错误。仅有启动前的完整扫描、目录描述符或只读挂载，不能证明整个执行期内容不变。

当前无已审核的生产 verifier/租约，也无绑定到主应用的可信固定锚。不要把离线工具接到 DshService 并声称身份防替换已完成；不要把直接把大文件树塞进 Manager 当作解决方案，这会违反现有 bundle 精确目录、条目数和大小门禁。

潜在替代是经授权的 root-owned 版本化目录和独立安装机制，具体见 `.build/dsh-control-integration-review/execution-boundary-assessment.md`。它需额外授权，而且仍须明确 Node entitlement、可写配置和进程身份的边界，不是已经验证的解决方案。

原 DshService 与 DshServiceTests 用户文件保持原样，未启动/关闭当前 Manager、浏览器和 DSH，未重置或请求 TCC。旧失败记录保留。构建制品仅为离线候选，不代表最新 UI 或实际运行中的 App。

## 更新：用户选择可进化的用户域方案

用户明确选择宽松限制，保留 DSH 的自我进化能力；其 DSH_HOME、agents 和工作目录继续可写。用户域运行时启动前校验不能抵御同 UID 在运行期间主动替换文件，此限制如实保留，原 Safarier CLI 身份和输入门禁没有放宽。

- Python 离线构建、安装、组装工具 39 项定向测试通过；Swift DshControlledRuntime 和 DshControlledService 联合 15 项通过。
- 固定锚与真实 runtime sidecar 在隔离目录完成安装、只读挂载、`node .../bin.js --version` 返回 `0.2.2-rc.1`、卸载。
- testing App 候选 `attempt-20261110-202325-99fa6a2dbb734b20878b30268f87c656` 源码前后 128 项一致，11 项 bundle 摘要和双签名核对通过。统一交付候选位于 `.build/dsh-integrated-testing-20261110-202325/`，App、runtime、安装工具摘要已独立核对。
- 已在 `~/Library/Application Support/Safarier/DSHRuntime/8a4c22bb334a3c307f8494cda029b80cd6a49545789e5e6087b878eef464baeb/` 安装版本化 sidecar 并复核 image 与 manifest SHA；未覆盖现有 DSH 用户数据。
- 此候选尚未更新安装 App，未真实 GUI、CLI+DSH 联合、TCC 授权验收。普通旧版仍运行，等待用户确认正常退出以测试。
