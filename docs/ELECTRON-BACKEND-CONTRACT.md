# Electron 组件客户端接口

> 历史背景：本文保留 Copis 上游实现/验证记录，所述 monorepo 路径及 Electron/COS 部署脚本不属于本独立仓库，不是当前构建步骤。当前入口见 [独立仓库 README](../README.md)。

模块文件：`apps/electron/src/main/lib/chrome-desktop-component-client.ts`。

```ts
import type { ChromeDesktopAllowedKey, ChromeDesktopBounds, ChromeDesktopWindowInfo } from '@copis/shared'

export interface ChromeDesktopComponentFrame {
  frameId: string
  width: number
  height: number
  capturedAt: number
  bounds: ChromeDesktopBounds
  data: string // JPEG base64，仅主进程到当前模型使用
}
export type ChromeDesktopComponentAction =
  | { action: 'click'; x: number; y: number; clickCount: 1 | 2 }
  | { action: 'scroll'; x: number; y: number; deltaY: number }
  | { action: 'type'; text: string }
  | { action: 'press'; key: ChromeDesktopAllowedKey }

export interface ChromeDesktopBackend {
  checkPermissions(): Promise<{ accessibility: boolean; screenRecording: boolean; helperPath: string; componentVersion: string }>
  listWindows(): Promise<ChromeDesktopWindowInfo[]>
  connectWindow(windowId: number, pid: number): Promise<ChromeDesktopWindowInfo>
  observe(): Promise<ChromeDesktopComponentFrame>
  input(frameId: string, action: ChromeDesktopComponentAction): Promise<void>
  selectFile(path: string): Promise<void>
  disconnect(): Promise<void>
  cancel(): Promise<void>
  stop(): void
}
export class ChromeDesktopComponentClient implements ChromeDesktopBackend { /* 注入依赖供BDD测试 */ }
```

`input` 的 x/y 是 Observe 图片坐标；不接收真实屏幕坐标，不需要 Electron 激活/焦点复查。客户端抛 Error，message 以前缀 `CHROME_<...>:` 标明对外错误：CONNECTION_BUSY/BUSY→CHROME_BUSY；FRAME_UNKNOWN→CHROME_FRAME_STALE；FRAME_GEOMETRY_CHANGED→CHROME_GEOMETRY_CHANGED；WINDOW_UNAVAILABLE→CHROME_WINDOW_UNAVAILABLE；FOCUS_LOST/FOCUS_UNVERIFIED/POINTER_OBSCURED/POINTER_UNVERIFIED→CHROME_FOCUS_LOST；permission→对应现有 CHROME_SCREEN_PERMISSION_REQUIRED/CHROME_INPUT_PERMISSION_REQUIRED；native timeout→CHROME_ACTION_UNCERTAIN；不存在或不可安装组件→CHROME_HELPER_FAILED（中文提示功能模块设置）。service 不依赖任意一条 renderer 帧。

组件端查找与按需安装仅通过 functional-module-manager/store：名字 chrome-desktop-cli。归档保留独立包顶层目录，manifest entrypoint 为 `copis-chrome-<version>-darwin-<arch>/copis-chrome`；helper 必须位于入口同目录，协议元数据 module.json 同目录且 version 与 active一致。不要假设每次版本 entrypoint固定，必须校验 basename 为 copis-chrome、helper为同目录。

每个 main 进程的私有 runtime 与用户CLI隔离；每个固定版本各自有runtime子目录，最长socket路径必须<=100字节。停止仅操作客户端自己创建的runtime，避免误停其他Agent的CLI。连接固定版本到 disconnect/cancel；新连接检查 active版本。CLI输出只接受protocolVersion=1且对象ok布尔值，stdout限长、响应超时有界；stderr不传递输入文本。check/list并发可串行，但原生 input 不自动重试；cancel直接并行停止本runtime，不能排在input后面。


v0.1.5 新增语义文件选择 `selectFile(path)`：调用 `select-file --connection <id> --path <absolute-file>`，不接收 `frameId`，要求回执 `connectionId` 匹配、`selected === true` 且 `dialogClosed === true`。Service 通过 `ChromeDesktopSelectFile({controlId, path})` 暴露，复用会话授权、串行输入门禁和 toolCallId 幂等缓存；可恢复的文件选择错误不要求重新授权。路径格式错误在调用 CLI 前拒绝，不回显参数。`FILE_DIALOG_*`、`FILE_NOT_READABLE`、`FILE_SELECTION_FAILED` 保留白名单具体错误映射；旧 CLI 不认识命令时提示更新组件，而非退回普通网页按键/坐标输入。成功后仍应 Observe 页面判断上传进度或服务端结果。
