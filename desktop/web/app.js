'use strict';
const $ = id => document.getElementById(id);
const invoke = (name, args) => {
  if (!window.__TAURI__?.core) return Promise.reject(new Error('请在 MCC 控制台 App 中打开。'));
  return window.__TAURI__.core.invoke(name, args);
};
let noticeTimer;
function notice(text, failed = false) {
  const el = $('notice');
  clearTimeout(noticeTimer);
  el.textContent = String(text);
  el.classList.toggle('error', failed);
  el.hidden = false;
  if (!failed) noticeTimer = setTimeout(() => {el.hidden = true;}, 5400);
}
function bind(id, fn) {
  $(id).addEventListener('click', async () => {
    const button = $(id);
    button.disabled = true;
    try { await fn(); } catch (error) { notice(error, true); }
    finally { button.disabled = false; syncButtons(); }
  });
}
for (const tab of document.querySelectorAll('[data-page]')) {
  tab.addEventListener('click', () => {
    for (const other of document.querySelectorAll('[data-page]')) {
      const active = other === tab;
      other.classList.toggle('active', active);
      if (active) other.setAttribute('aria-current','page'); else other.removeAttribute('aria-current');
      $(other.dataset.page).hidden = !active;
    }
    $('notice').hidden = true;
  });
}

const hostFields = ['address', 'port', 'certificate', 'private_key', 'token_file'];
let hostState, settingsDirty = false, initialized = false, transitioning = false;
function syncButtons() {
  $('host-start').disabled = !initialized || !hostState || settingsDirty || hostState.phase !== 'stopped' || transitioning;
  $('host-stop').disabled = !hostState || hostState.phase !== 'running' || transitioning;
  for (const button of document.querySelectorAll('[data-saved]')) button.disabled = !selected || scriptDirty;
}
function markSettings(dirty) {
  settingsDirty = dirty;
  $('save-state').textContent = dirty ? '有未保存的配置。' : '保存后在下次启动时应用。';
  syncButtons();
}
function displayHost(state) {
  hostState = state;
  $('host-state').textContent = {starting:'正在启动…',running:'Host 正在监听',stopping:'正在安全停止…',stopped:'本面板未启动 Host'}[state.phase];
  $('host-dot').className = `dot ${state.phase}`;
  $('host-detail').textContent = [state.listen, state.message].filter(Boolean).join(' · ');
  syncButtons();
}
async function pollHost() { displayHost(await invoke('host_status')); }
for (const button of document.querySelectorAll('[data-pick]')) {
  bind(button.id = `pick-${button.dataset.pick}`, async () => {
    const field = button.dataset.pick;
    const path = await invoke('choose_path', {folder: field === 'bin_dir'});
    if (path) {$(field).value = path; markSettings(true);}
  });
}
$('host-form').addEventListener('input', event => {
  if (event.target.id !== 'identity') markSettings(true);
});
$('host-form').addEventListener('submit', async event => {
  event.preventDefault();
  const button = event.submitter;
  if (button) button.disabled = true;
  try {
    const host = Object.fromEntries(hostFields.map(name => [name, $(name).value.trim()]));
    host.port = Number(host.port);
    await invoke('save_settings', {value: {host, bin_dir: $('bin_dir').value.trim()}});
    markSettings(false); notice('Host 配置已保存。');
  } catch (e) {notice(e, true);} finally {if (button) button.disabled = false;}
});
bind('token', async () => {
  $('token_file').value = await invoke('generate_token'); markSettings(true);
  notice('已生成新 token 文件。保存配置后，下次启动时使用。');
});
bind('tls', async () => {
  const identity = $('identity').value.trim();
  if (!identity) throw new Error('请输入客户端访问时使用的域名或 IP。');
  const bundle = await invoke('generate_tls', {identity});
  $('certificate').value = bundle.certificate; $('private_key').value = bundle.privateKey;
  markSettings(true); notice(`证书已生成。客户端 CA 文件：${bundle.caCert}`);
});
for (const op of ['start','stop']) bind(`host-${op}`, async () => {
  transitioning = true;
  try {displayHost(await invoke(`host_${op}`));} finally {transitioning = false;}
});

function displayDevice(device) {
  $('ble-current').textContent = device ? device.name : '默认：pilot-2';
  $('ble-id').textContent = device?.id ?? '尚未指定设备 UUID';
  $('device-id').value = device?.id ?? '';
}
function deviceList(items, empty) {
  const list = $('device-list');
  list.replaceChildren();
  if (!items.length) {
    const p = document.createElement('p'); p.className = 'empty'; p.textContent = empty; list.append(p);
  }
  for (const device of items) {
    const button = document.createElement('button');
    button.append(document.createTextNode(device.name));
    const id = document.createElement('small'); id.textContent = device.id; button.append(id);
    button.addEventListener('click', () => {
      for (const child of list.children) child.classList.toggle('selected', child === button);
      $('device-id').value = device.id;
    });
    list.append(button);
  }
}
bind('scan', async () => {
  deviceList([], '正在扫描附近设备…');
  try {deviceList(await invoke('ble_discover'), '没有发现命令服务。确认设备已上电并靠近本机，或输入已知 UUID。');}
  catch (e) {deviceList([], '扫描未完成。'); throw e;}
});
for (const [action, save] of [['ble-test',false],['ble-save',true]]) bind(action, async () => {
  const id = $('device-id').value.trim();
  if (!/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(id)) throw new Error('请选择设备或输入有效的设备 UUID。');
  const device = await invoke('ble_test', {id, save});
  if (save) displayDevice(device);
  notice(`${device.name} 已返回状态${save ? '，设备选择已保存' : ''}。`);
});
bind('ble-reset', async () => {await invoke('ble_clear'); displayDevice(null); notice('已恢复 pilot-2 默认选择。');});

let items = [], selected = null, scriptDirty = false;
const template = JSON.stringify({version:1,steps:[{action:'observe'}]}, null, 2) + '\n';
function scriptSummary() {
  try {
    const steps = JSON.parse($('script-json').value).steps;
    if (!Array.isArray(steps)) throw Error();
    const eb = steps.flatMap((step, i) => step?.eb === true ? [i+1] : []);
    $('esp-steps').textContent = eb.length ? `ESP：第 ${eb.join('、')} 步` : 'ESP：无';
  } catch { $('esp-steps').textContent = '待校验 JSON'; }
}
function showError(message = '') {
  $('script-error').textContent = message;
  $('script-error').hidden = !message;
}
function openScript(script) {
  selected = script;
  scriptDirty = false;
  $('script-name').value = script?.name ?? '';
  $('script-json').value = script?.content ?? template;
  $('command-group').hidden = true;
  showError(); scriptSummary(); renderScripts(); syncButtons();
}
function discardAllowed() { return !scriptDirty || window.confirm('此脚本有未保存的更改。要放弃这些更改吗？'); }
function renderScripts() {
  const list = $('script-list'); list.replaceChildren();
  $('script-count').textContent = items.length;
  const q = $('search').value.trim().toLowerCase();
  const filtered = items.filter(item => item.name.toLowerCase().includes(q));
  for (const script of filtered) {
    const button = document.createElement('button');
    button.textContent = script.name;
    if (script.id === selected?.id) button.classList.add('selected');
    if (script.needs_frame) {const small = document.createElement('small'); small.textContent = '需要初始帧'; button.append(small);}
    button.addEventListener('click', () => {if (script.id !== selected?.id && discardAllowed()) openScript(script);});
    list.append(button);
  }
  if (!filtered.length) {const p=document.createElement('p');p.className='empty';p.textContent=q?'没有匹配的脚本。':'还没有脚本。可以新建或导入 JSON。';list.append(p);}
}
for (const id of ['script-name','script-json']) $(id).addEventListener('input', () => {scriptDirty = true; $('command-group').hidden = true; showError(); scriptSummary(); syncButtons();});
$('search').addEventListener('input', renderScripts);
async function refreshScripts(item) {items = await invoke('scripts'); openScript(item);}
bind('script-new', async () => {if (discardAllowed()) {openScript(null); $('script-name').focus();}});
bind('script-import', async () => {
  if (!discardAllowed()) return;
  const item = await invoke('script_import');
  if (item) {await refreshScripts(item); notice('已导入脚本库。');}
});
bind('script-save', async () => {
  showError();
  try {
    const item = await invoke('script_save', {id: selected?.id ?? null, name: $('script-name').value, content: $('script-json').value});
    await refreshScripts(item);
    notice(item.needs_frame ? '已保存。运行时须提供初始帧。' : '脚本已校验并保存。');
  } catch (e) {showError(String(e));}
});
bind('script-copy', async () => {
  if (!selected) return;
  const name = Array.from(selected.name).slice(0,95).join('') + ' 副本';
  const item = await invoke('script_save', {id:null, name, content:selected.content});
  await refreshScripts(item); notice('已创建脚本副本。');
});
bind('script-export', async () => {if (selected && await invoke('script_export', {id:selected.id})) notice('已导出 JSON。');});
bind('script-delete', async () => {
  if (!selected || !window.confirm(`从脚本库删除「${selected.name}」？`)) return;
  await invoke('script_delete', {id:selected.id}); await refreshScripts(null); notice('已从脚本库删除。');
});
bind('script-command', async () => {
  if (!selected) return;
  const path = await invoke('script_path', {id:selected.id});
  const quoted = "'" + path.replaceAll("'", "'\\''") + "'";
  $('command-text').value = `mcc script --connection 'CONNECTION_ID' --file ${quoted}${selected.needs_frame ? " --frame 'FRAME_ID'" : ''}`;
  $('command-group').hidden = false;
  $('command-text').select();
  try {await navigator.clipboard.writeText($('command-text').value); notice('已复制 CLI 命令。');}
  catch {notice('命令已选中，可按 ⌘C 复制。');}
});
openScript(null);
Promise.allSettled([
  invoke('settings').then(value => {for (const name of hostFields) $(name).value = value.host[name]; $('bin_dir').value = value.bin_dir; initialized = true;}),
  invoke('ble_selection').then(displayDevice),
  refreshScripts(null),
  pollHost(),
]).then(results => {
  const failed = results.find(r => r.status === 'rejected');
  if (failed) notice(failed.reason, true);
  syncButtons();
});
if (window.__TAURI__?.core) setInterval(() => { if (!transitioning) pollHost().catch(e => notice(e, true)); }, 900);
