# Bundle 清单祖先目录竞态：定向验证

针对 `browser-multistep-errors.md` C 项调查。原始 `inventoryAfter result=4` 不包含具体差异，无法证明历史故障由本记录所复现的竞态引起，也无法据此忽略真实包变化。

`BundleInventory.open_root` 和 `BinderIdentity.snapshot_impl` 原来在持有路径 fd 后，将祖先目录全部 stat 字段复核；同级无关项目创建会改变祖先目录的 mtime、ctime，创建子目录也可能改变 nlink。受控 fixture 在两处检查的复核前同步创建同级目录，原版分别返回 `BB_CHANGED=4` 和 `BI_CHANGED=4`，见 `.build/control-multistep-fix-20261116/inventory/red.log` 和 `binder-red.log`。测试使用仅在临时副本插入的 checkpoint，不向生产代码添加测试钩子。

修复改为比较祖先目录的设备、inode、模式、owner、group、flags、birthtime 和 extended ACL，仍对每一级进行路径映射复核；Binder 的 reopen 也复核祖先 ACL。忽略祖先非权限 xattr 及同级内容造成的 mtime、ctime、size、nlink 变化。包根及包内目录和文件仍保留原完整 stat、元数据、内容哈希、代码签名验证，不对失败结果自动重试或转成功。新增固定标签诊断以区分祖先映射、根映射、inventory 扫描或清单 pin 差异，不记录路径或文件内容。

定向验证（独立 clang fixture，未运行全量回归）：

```sh
python3 scripts/test-binder-ancestor-race.py
python3 scripts/test-bundle-ancestor-race.py
python3 scripts/test-bundle-revalidation-trace.py
```

前两项均验证 5 个确定性场景：同级新增目录通过；祖先 chmod、祖先 ACL 添加、祖先 rename 并替换为 symlink 均拒绝；Binder 的目标文件改变、Bundle 的根目录改变均拒绝。ACL 场景同时核对 Binder 的 `BI_F_ACL` 诊断位。最后一项验证真实 ad-hoc 签名 fixture 的合法包、错误标识、过期、包内文件改变，以及路径不出现在诊断输出中。最终日志分别为 `.build/control-multistep-fix-20261116/inventory/binder-final.log`、`bundle-final.log` 和 `signed-final.log`。

未修改、安装或重启现有用户 App、浏览器及 daemon；尚未对新的生产包执行端到端验证。祖先 ACL 读取和比较增加了系统调用，其真实运行环境与现有期限预算的表现仍待安装后测量。

主 Agent 已独立复核上述 C 源码、fixture 和脚本，并重新运行全部三条定向命令，均退出 0。两组各 5 个竞态场景结果符合预期，签名验证 fixture 通过；独立日志为同目录的 `main-binder.log`、`main-bundle.log`、`main-signed.log`。此结果验证复现的祖先目录竞态修复，不把历史组 6 的具体原因视为已证实。
