# v0.3.2 指定现有Chrome profile

用户已确认实现；基线为已推送标签0.3.1/提交a9d3927cdc1c0ed2d584b81b3184bdc9d9e0763b。保留标签和已有产物，不擅自提交/推送/安装本版。

## 契约
- `mcc chrome start --profile mcc [--url ...]`：按Chrome显示名称精确匹配默认用户数据目录Local State的profile.info_cache，匹配为现存安全basename目录；缺失、重名、目录无效/替换明确拒绝，不创建profile、不静默回退。
- 可选默认值通过现有`--config chrome --profile mcc`写config.toml的[chrome].profile；`--clear-profile`清除。显式CLI优先；未配置/未指定时保持0.3.1启动路径。配置命令仍只写mcc配置，不修改Chrome数据、不启动daemon。
- 本机已知显示名mcc对应Profile 2，但运行时必须重新读取，不硬编码。只返回选中的name/directory，不输出邮箱、Google账户ID、Cookie或其他profile私有元数据。
- AppleScript make new window使用lastProfile，不能用作显式profile创建。指定时由系统open启动同一Chrome、明确user-data-dir/profile-directory/new-window，初始只打开私有frames目录中的一次性静态HTML标记（无脚本/外部资源，Rust复用现有帧目录生命周期清理）。通过精确CG/AX窗口的AXDocument读取唯一标记，旧窗或重复标记拒绝。仅对该新窗用原AX setter设置A→B，再由只读AppleScript receipt证明同一对象与同一CGWindowID/PID对应，复用原布局与回读；不先用AS猜测对象后修改几何，不靠front window或唯一差集猜测。
- 缺失profile不得被Chrome自动创建：使用防创建标志，启动前后复核所选目录身份与映射；不存在时不导航业务URL/不建立控制连接。匹配标记后、导航最终URL前复核，绝不因为Chrome缺失profile回退而继续业务操作。
- 不另起CDP/DOM/页面JS或独立浏览器数据目录。不搬运登录态、不杀其他Chrome进程、不改变原点击/焦点/暂停/倒计时/截图门禁。

## 分工与验证
- 并行实现仅限Rust参数/配置；主agent负责native resolver/启动与service集成，全部review由主agent执行。
- TDD：名称/重复/目录穿越/普通文件/符号链接/不存在/目录替换/有界JSON；CLI、配置默认及覆盖、service参数与回执；现有无profile行为回归。
- Rust串行全套、native smoke、build/package/install临时路径、密钥检查。
- 实机：未知名称无副作用；显式mcc启动，原窗口几何不变；通过原有输入链导航chrome://version并用本地截图确认Profile Path为Profile 2（非生产新增OCR门禁），不读取Cookie，不自动登录/发布。若USER_PAUSED立即停止，不绕过。
- 所有控制只用任务私有runtime，最终disconnect/daemon stop并确认running:false。只读/配置/纯fake测试不冒充实机验收。

实机发现Chrome156把命令行about:blank#nonce丢为newtab；保留此失败证据，改用内部受控文件URL，不回退唯一差集或错误profile。
