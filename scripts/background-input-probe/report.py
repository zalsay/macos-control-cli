#!/usr/bin/env python3
"""Summarize actual fixture evidence, including failed experiments and scope limits."""
import argparse, datetime, hashlib, json, pathlib, plistlib, re, subprocess, zoneinfo
p=argparse.ArgumentParser()
p.add_argument('--prefix',default='acceptance-native-pointer')
p.add_argument('--control-label',default='acceptance-no-input-control')
a=p.parse_args()
if any(not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,100}',value) for value in (a.prefix,a.control_label)):p.error('unsafe prefix or control label')
repo=pathlib.Path(__file__).resolve().parents[2]
root=repo/'.build/mcc-safarier-probe'
m=json.loads((root/f'{a.prefix}-matrix.json').read_text())
assert m['allPassed'] and len(m['runs'])==9,'Repeat matrix is not green'
required={'hover','hover_pointer_semantics','hover_exit','custom_pointer_drag_buttons','held_state_is_process_local','held_state_releases_to_zero','pointer_down_buttons_semantics','drag_events_have_held_button','temporary_queries_restored','password_without_global_secure_input','background_cursor_write_protection','no_global_input_or_activation'}
rows=[];stable=[]
for row in m['runs']:
 d=json.loads((root/'runs'/row['label']/'report.json').read_text())
 assert d['allPassed'] and len(d['cases'])==25
 cases={c['name']:c for c in d['cases']}
 assert required<=cases.keys() and all(c['passed'] for c in d['cases'])
 safety=cases['no_global_input_or_activation']
 assert safety['ownGlobalPointerEvents']==0 and not safety['ownActivationObserved']
 assert safety['globalMonitorInstalled'] and safety['localMonitorInstalled']
 assert all(not s['ownAppActive'] and not s['ownWindowKey'] for s in d['samples'])
 assert safety['final']['cursorGuard'] and safety['fixtureIgnoresPhysicalClicks']
 previous=None
 for c in d['cases']:
  current=c.get('safety')
  if current and previous and c['name'] in ('hover','hover_exit','click','double_click','custom_pointer_drag_buttons','held_state_is_process_local','text_ascii','text_unicode'):
   span=[previous]+[s for s in d['samples'] if previous['time']<=s['time']<=current['time']]+[current]
   positions={(s['cursorX'],s['cursorY']) for s in span}
   shapes={s['cursorShape'] for s in span}
   if len(span)>=4 and len(positions)==1 and len(shapes)==1 and 'unavailable' not in shapes:
    stable.append({'run':row['label'],'phase':c['name'],'samples':len(span),'duration':current['time']-previous['time']})
  if current:previous=current
 secureValues=sorted({s['secureInput'] for s in d['samples']})
 sourceValues=sorted({s['keyboardInputSource'] for s in d['samples']})
 rows.append({'run':row['label'],'state':row['state'],'checks':len(d['cases']),'samples':safety['sampleCount'],'externalPointerEvents':safety['externalPointerEvents'],'externalKeyboardEvents':safety.get('externalKeyboardEvents',0),'externalModifierEvents':safety.get('externalModifierEvents',0),'ownGlobalPointerEvents':0,'ownActivationObserved':False,'suppressedCursorWrites':cases['background_cursor_write_protection']['suppressedWrites'],'secureInputObserved':secureValues,'inputSourceCount':len(sourceValues),'cursorShapeObserved':safety['cursorShapeObserved']})
unit=(root/'toolchain/native-input-tests.log').read_text()
assert 'NATIVE_BRIDGE_SELFTEST_OK checks=30' in unit
control=json.loads((root/'runs'/a.control_label/'report.json').read_text())
assert not control['allPassed'] and not next(c for c in control['cases'] if c['name']=='click')['passed']
webKit=plistlib.load(open('/System/Library/Frameworks/WebKit.framework/Resources/Info.plist','rb'))['CFBundleVersion']
binary=root/'BackgroundInputProbe.app/Contents/MacOS/BackgroundInputProbe'
files=[repo/'Sources/SafarierObjCSupport/SFRRuntime.m',repo/'Sources/SafarierObjCSupport/include/SafarierObjCSupport.h',repo/'Tests/NativeInput/ScopedMouseStateTests.m',*sorted((repo/'scripts/background-input-probe').glob('*.swift')),*sorted((repo/'scripts/background-input-probe').glob('*.html'))]
summary={'date':datetime.datetime.now(zoneinfo.ZoneInfo('Asia/Shanghai')).isoformat(),'branch':subprocess.check_output(['git','branch','--show-current'],cwd=repo,text=True).strip(),'baseline':subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip(),'webKitBuild':webKit,'nativeChecks':30,'guiChecksPerRun':25,'guiRuns':rows,'allPassed':True,'stableObservedSegments':stable,'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),'sourceSHA256':{str(f.relative_to(repo)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files}}
(root/f'{a.prefix}-summary.json').write_text(json.dumps(summary,indent=2,ensure_ascii=False))
lines=['# 后台原生悬停与按住状态修复验证','',f'- 日期：{summary["date"]}',f'- 分支：`{summary["branch"]}`；基线：`{summary["baseline"]}`。',f'- 平台：macOS 26.6.2 / arm64；WebKit `{webKit}`；Swift 6.3.3。','- 结论：本次范围内修复已通过重复验证；不是完整产品、任意网页或跨版本验收。','', '## 实现与安全边界','',
'1. 悬停：WebKit 对 inactive 页面且无按键的移动只做滚动条命中。通过本进程的页面活动上下文解决，不调用真实窗口激活；窗口查询仅对已核验 WebKit image 的调用点提供逻辑结果，AppKit/应用本身始终走原查询。','2. 按住状态：使用主线程 TLS 逻辑按钮状态；原生事件发送期间为 down/drag=1、up=0；查询 IMP 在正常返回、异常、嵌套后恢复。静态 C IMP 不会在并发读者还在执行时被释放。','3. 时序：使用原生 pending-mouse completion，不把固定等待当作动作完成；避免多次纯移动合并后阻塞后续点击。输入文字前先等待指针动作与只读状态回执。','4. 后台光标保护：本 Runner 内的 NSCursor 设置/隐藏写入被抑制；主线程且真实 App 为前台时透传原函数。该保护有意常驻至 Runner 退出，以覆盖迟到的按键回执；不是临时查询，不能宣称结束连接时撤销了所有方法替换。其它进程不受影响。','5. 不使用全局 CGEvent 投递、鼠标移动/键盘兜底、AppleScript System Events、DOM click/dispatchEvent 或生产网页脚本注入。未请求屏幕录制、辅助功能或其它新权限。','6. 只在已验证 WebKit 构建启用；缺接口、签名不符、来源无法核验或已有方法被其它组件替换时明确失败，不扩大控制范围。','', '## 验证结果','', '- 原生检查：30 项通过，包括异常、嵌套、100 次串行状态范围、2000 次并发范围切换、不向工作线程泄漏状态、错误 ABI/事件拒绝、光标保护前后台策略、窗口查询调用来源隔离。光标策略使用原函数替身，不调用真实系统光标写入。','- 无输入对照组的输入功能检查按预期失败，不会因为命令被调用而假阳性。该组另有一次无输入光标图像变化的观察失败，尚未归因；不将全局图像变化单独解释为本程序改动，原始记录保留。','- 最终 GUI 矩阵：失焦、遮挡、隐藏各 3 轮，共 9 轮 × 25 项 = 225 项检查，全部通过。隐藏是 orderOut，不等于最小化或跨 Space。','', '| 轮次 | 状态 | 检查 | 外部鼠标事件 | 外部键盘/修饰键计数 | 自身全局鼠标事件 | 拦截光标写入 |', '|---|---|---:|---:|---:|---:|---:|']
for r in rows:lines.append(f'| {r["run"]} | {r["state"]} | {r["checks"]}/25 | {r["externalPointerEvents"]} | {r["externalKeyboardEvents"]+r["externalModifierEvents"]} | 0 | {r["suppressedCursorWrites"]} |')
lines+=['',f'- 静止采样片段：记录到 {len(stable)} 个有实际页面动作、系统位置和光标图像保持稳定的区间；完整明细见 summary JSON。未强迫用户停止使用设备。','- 所有轮次目标 App 均未成为前台、目标窗口均未成为真实 key window；密码框输入未改变该阶段的全局 Secure Input。','- 只读取 HID 事件数量，不记录外部按键内容。外部键盘动作可能合法改变系统光标，不能把“没有鼠标移动”误当成“用户没有任何活动”。','- 诊断页只记录自身输入和原生控件后置条件；键值不写入日志，意外文本被脱敏，失败时不保存页面截图。没有真实账号/订阅或持久 profile。','', '## 25 项页面与安全检查','']
firstReport=json.loads((root/'runs'/m['runs'][0]['label']/'report.json').read_text())
lines.extend(f'- `{case["name"]}`' for case in firstReport['cases'])
lines+=['', '## 测试宿主与此前失败记录','', '- 使用原仓库 BrowserWebView、BrowserWindowController 及原始配置工厂。测试入口替代正常 Runner 启动，宿主为 LSUIElement/accessory、无 Dock 图标、物理鼠标点击穿透，避免测试窗口截获用户操作；不把它等同正式 Runner UI 验收。','- 首次矩阵有一次光标变化安全检查失败、一次 App 被激活。旧检查未区分外部键盘活动；激活没有唯一归因，未冒充成功或删除记录。随后缩小逻辑查询来源，并隔离测试宿主的 Dock/物理输入，再得到两组全绿矩阵；以本文件的最终矩阵为准。','- 更早的启动超时已采样到 dyld 打开包外测试动态库、未进入 main。当前原型改为静态链接，最终矩阵没有该启动超时。未改 Gatekeeper、TCC 或系统工具链。','- CLI 光标策略测试曾因未初始化 GUI 工厂得到 nil cursor 而异常；生产能力检查已补 nil 拒绝，策略单测改用纯替身，真实工厂由 GUI 验证。','- 正常 SwiftPM 清单仍有宿主 PackageDescription ABI 链接问题；当前 CommandLineTools 中未发现 XCTest.framework。本次严格编译/执行独立原生测试，并直接编译实际模块与应用类，不宣称常规 swift test 或整个工程构建全绿。','', '## 尚未覆盖/未交付','', '- AppleScript 正式命令入口、完整 Runner 启动、新标签/新窗口、全屏、指针锁、原生菜单、文件/权限弹窗及真实业务账号。','- 真实中文 IME 连续组词体验、人工前台 Safarier 体验、多显示器、最小化、跨 Space、其它 macOS/WebKit 构建。Unicode 字符输入通过不等于所有 IME 输入行为相同。','- 正常 Runner 原有主动激活启动路径未改；对任意网页的 UI 逃逸/全屏/弹窗还需正式接入时的门禁，不能将本次本地页验证说成所有网站均安全可用。','- 未安装或替换用户现有 App，未提交、推送、合并或发布。源码评审仅由主代理执行。','', '## 复现','', '```sh', f'cd "{repo}"','scripts/verify-background-input.sh --prefix YOUR_UNIQUE_PREFIX --rounds 3','scripts/background-input-probe/run.py --mode stub --label YOUR_UNIQUE_CONTROL --expect-red','scripts/background-input-probe/report.py --prefix YOUR_UNIQUE_PREFIX --control-label YOUR_UNIQUE_CONTROL','```','', '## 证据','', f'- `.build/mcc-safarier-probe/{a.prefix}-matrix.json`', f'- `.build/mcc-safarier-probe/{a.prefix}-summary.json`', '- `.build/mcc-safarier-probe/runs/<轮次>/report.json` 与 `page.png`', '- `.build/mcc-safarier-probe/toolchain/native-input-tests.log`', f'- 最终可执行文件 SHA-256：`{summary["binarySHA256"]}`','']
doc=repo/'docs/verification/2026-10-28-background-pointer.md';doc.parent.mkdir(parents=True,exist_ok=True);doc.write_text('\n'.join(lines))
print(doc)
print(json.dumps({'runs':len(rows),'guiChecks':sum(r['checks'] for r in rows),'nativeChecks':30,'externalPointerEvents':sum(r['externalPointerEvents'] for r in rows),'externalKeyboardAndModifierEvents':sum(r['externalKeyboardEvents']+r['externalModifierEvents'] for r in rows),'suppressedCursorWrites':sum(r['suppressedCursorWrites'] for r in rows),'stableSegments':len(stable)},ensure_ascii=False))
