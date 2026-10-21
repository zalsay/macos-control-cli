# v0.1.11 同帧 OCR 文字定位验证

日期：2026-10-21。协议版本保持1。只返回文字，不判断控件类型。

## 已验证行为

- Observe 分析实际交付的 JPEG，返回 `ocr:{status,truncated,items}`；每条包含 text、bbox、center、confidence。
- 坐标使用原截图像素和左上角原点；文字框不是控件边界，中心点不保证可点击。
- 中文/英文识别；不添加 OpenCV 或其他第三方依赖，不读取网页 DOM/AX，不激活 Chrome。
- OCR 分析等待预算3秒；失败、超时或前次分析尚未退出时降级，不阻塞有效截图。不积压后续分析任务。
- 原任务取消仍返回 CANCELLED，不能把取消当作普通 OCR 失败；保留原窗口几何复核。
- 上限128项、每项256个 Unicode scalar、总量8192个且序列化不超过48KiB；超限显式 truncated。
- Rust 与 Electron 适配端复核数量、大小、坐标边界、中心点和置信度。旧组件无 OCR 字段继续提供截图。
- 内置 Agent 随截图获得 `untrusted_chrome_ocr` 文字块，不把网页文字当成指令。

## 回归与构建

新增 BDD 覆盖坐标转换、Retina 原像素、无控件类型、空/非法观测、条数/文字/JSON转义字节上限、失败降级、超时不积压、取消、实际离线 Vision 识别；Rust 验证同帧透传、无输入和非法结果降级；Electron 验证组件解析、服务透传和 Pi Worker 文字块。

全仓 typecheck、Electron main 和 Pi Worker 构建通过。Rust 67项、153项原生 JSONL smoke 及同脚本原生 BDD 通过；模块构建/版本锁相关28项通过。各 Electron 测试单独进程运行，防止 mock 互相污染。

## 真实 Chrome 只读测试

以独立 runtime 连接用户已授权的视频号窗口，仅执行 windows/connect/observe/disconnect/daemon stop。

- 图像：1212×1310，screen-capture-kit，frame-pixels，crop-only；未缩放。
- OCR：status=ok，61条文字。
- 单次整个 Observe 耗时约1.286秒；不代表其他机器或页面的性能保证。
- “发表视频”：文字框 x=1041,y=583,width=76,height=20，中心 x=1079,y=593，未推断类型，未点击。
- 本次未上传、发表、输入或切换用户页面；结束确认 running=false。

原始截图与结果保存在本次本机临时验证目录，不提交包含账号信息的图片或完整 OCR 数据。

## 大回执修复

真实回归最初得到“协议行缺少换行符”；原始 socket 回执只有8192字节，完整结果应为8732字节。临时诊断确认 write_all 遇到 EAGAIN，原因是 macOS accept 继承 listener 的非阻塞状态。正式代码在接收客户端后恢复阻塞读写并保留读写超时；大于 socket 缓冲的完整 JSONL 回归和真实 Observe 均通过。没有提高64KiB协议上限，也没有截断 JSON 来掩盖问题。
