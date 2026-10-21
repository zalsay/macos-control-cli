# Chrome 组件统一更新与部署（2026-10-19）

> 历史背景：本文保留 Copis 上游实现/验证记录，所述 monorepo 路径及 Electron/COS 部署脚本不属于本独立仓库，不是当前构建步骤。当前入口见 [独立仓库 README](../README.md)。

## 已明确的行为

用户要求组件更新和部署纳入统一“关于/更新”管理，deploy 支持 `--chrome-cli` 构建并上传。复用已有关于页、Jotai功能模块状态、SHA256/manifest发布机制与独立版本锁，不增加一套组件更新器，不自动随意递增版本。

- 关于/更新继续承载本地能力组件列表；Chrome仅macOS可见，支持逐组件安装、检查、升级和进度。
- 加入“检查全部组件更新”，单个失败不影响其他组件；主程序更新提醒同时考虑已发现的组件更新。
- Chrome工具里的组件安装/更新提示可直接跳转关于/更新，避免入口文案不准确。
- `deploy.sh --chrome-cli` 与PowerShell长开关兼容，等价于原Chrome-only选择；非macOS明确拒绝，不构建Rust HTTP API或其他模块。
- 默认不传归档时每次从当前源码构建Rust+Swift组件，不复用resources中的旧tar；显式传archive时校验后发布。
- `--chrome-cli-archive`、`--chrome-cli-version` 提供对应短参数，原 `--chrome-desktop-cli*` 继续可用。manifest/publish入口同样识别短参数。
- 版本以 `scripts/functional-module-versions.json` 锁定值为准，保持当前Cargo/归档一致；新版本发布需先调整统一版本锁和Cargo版本，不静默覆盖已发布的不可变对象。
- 默认执行发布阶段；`--skip-publish` 可仅本地构建校验。单模块发布合并远端manifest并保留其他模块和平台。

## 执行与验证计划

- [x] UI和Jotai入口：先写BDD失败场景，再增加批量检查、更新提醒和关于页直达，不改变组件安装/输入控制边界。
- [x] 部署脚本：先写真实脚本进程BDD，以隔离Bun/编译/上传fixture验证 --chrome-cli 到build/prepare/publish的完整调用链及skip-publish分支。
- [x] prepare/manifest/publish短参数：本地真实归档与stub验证构建、不可混选、平台拒绝、旧参数兼容。
- [x] 验证typecheck、针对性Bun/Rust回归、renderer/main构建与脚本语法；独立审查。
- [x] 更新组件说明和操作命令，保留root README/AGENTS未授权编辑边界。

本轮的上线动作以用户实际执行部署命令为入口；测试上传使用隔离fixture，不将测试manifest写入真实COS。Electron UI最终交互由用户在真实窗口确认，Agent不使用截图代替验收。

## 验证记录

- 部署短入口18项真实脚本进程BDD通过：默认构建/manifest/上传顺序、skip-publish、已有归档、旧参数、显式install、失败阻断、平台/混选/缺值与别名冲突、同值兼容和环境覆盖。
- 短/长配置解析8项BDD通过；manifest/publish短入口由真实Bun进程验证，包含非macOS和混选拒绝。
- 本机实际执行 `bash ./deploy.sh --chrome-cli --skip-publish --platform darwin --arch arm64`，成功从源码生成v0.1.0 ARM64双二进制归档；短参数生成本地manifest成功，含SHA256与独立版本入口。
- 全workspace typecheck和发布脚本额外TypeScript检查通过，renderer构建通过；构建仅有既有chunk体积提示。
- 关于页实际组件渲染测试验证批量检查、Chrome升级与Jotai进度；更新提醒、可选未安装不提醒、Banner直达about有BDD覆盖。
- PowerShell当前环境无pwsh，保留参数/发布边界的静态约束测试，不声称已运行PowerShell或真实Windows部署。
- 独立简化/正确性审查发现的参数别名冲突已通过失败回归复现并修复；两个deploy入口都拒绝显式冲突值。

未修改根README/AGENTS，未提交、合并或推送。界面视觉与真实交互仍需用户在Electron窗口确认，未使用截图代替验收。当前环境没有专用@code-simplifier，已执行独立审查与简化检查。

最终交付验证：17个相关Bun文件共161项通过；工作区及部署脚本TypeScript检查、renderer构建和Bash语法检查通过。独立复核确认参数冲突问题关闭。批量检查状态使用共享Jotai atom，同步防重且跨关于页卸载/重挂载保留；新增重挂载回归通过。
