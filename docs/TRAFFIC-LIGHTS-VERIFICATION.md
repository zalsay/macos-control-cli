# v0.1.9 原生三联按钮

日期：2026-10-21。独立组件版本0.1.9，JSON协议仍为1。

本轮仅在现有NSPanel内替换窗口样式和关闭控件，没有叠加仿制三色按钮、新浮层或控制服务。使用titled/closable/fullSizeContentView/nonactivatingPanel，隐藏窗口标题并让标题栏透明；不启用miniaturizable/resizable，因此系统黄色/绿色按钮保持禁用，红色关闭接入原有pauseExecution后dismiss路径。

窗口仍为560×80、屏幕上方80点边距，不抢键盘或主窗口焦点。原生标题栏不开放拖动；Logo和两行文字放在三联按钮下方，主标题位于状态说明上方。

## BDD

```text
Given 控制条已展示
Then close/minimize/zoom均来自NSWindow.standardWindowButton
And 红色可用，黄色/绿色禁用
And 第一次点击红色关闭可触发原有暂停路径

Given 288点宽的可用控制条
Then 原生三联按钮、Logo、标题和状态文字均未被裁切
And 三联按钮不与Logo或文字相交

Given 关闭前存在输入代次或倒计时
When 原生红色关闭被按下
Then 输入保持USER_PAUSED，提示隐藏且旧计时器不复活
And 新的Observe标题刷新不显示提示、不恢复输入
```

原生AppKit对象回归先因缺少系统三联按钮失败；替换后核对真实standardWindowButton对象、enabled、frame、firstMouse及关闭门禁。布局检查使用对象几何，不通过截图代替用户视觉验收。不操作用户Chrome或发送真实鼠标/键盘事件。

本轮没有修改坐标映射、截图分辨率、输入许可状态机或系统权限流程。需由用户在真实窗口确认原生按钮外观和正文排版。
