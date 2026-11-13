import Foundation
import WebKit
import SafarierCore

/// 负责浏览器前端页面与原生端之间的表单自动填写与凭据捕获桥接。
@MainActor
protocol FormAutofillBridgeDelegate: AnyObject {
    /// 网页提交了表单并提取到用户名与密码。
    func formAutofillBridge(
        _ bridge: FormAutofillBridge,
        didSubmitCredentials domain: String,
        username: String,
        password: String
    )
}

@MainActor
final class FormAutofillBridge: NSObject, WKScriptMessageHandler {
    static let messageHandlerName = "safarierAutofill"

    weak var delegate: FormAutofillBridgeDelegate?

    /// 预先注入的表单探测、建议下拉框与提交捕获脚本
    static var userScript: WKUserScript {
        let source = """
        (function() {
            if (window.__safarierAutofillInstalled) return;
            window.__safarierAutofillInstalled = true;
            window.__safarierAutofilling = false;
            window.__safarierActiveInput = null;

            function getDomain() {
                try {
                    return window.location.hostname || '';
                } catch(e) {
                    return '';
                }
            }

            function findUsernameInput(passInput) {
                const form = passInput.form || passInput.closest('form') || document;
                const inputs = Array.from(form.querySelectorAll('input'));
                // 优先寻找明确标识为 username/email/account/phone/mobile 的输入框
                let cand = inputs.find(i => {
                    if (i.type === 'password' || i.type === 'hidden' || i.type === 'submit' || i.type === 'button') return false;
                    const name = (i.name || '').toLowerCase();
                    const id = (i.id || '').toLowerCase();
                    const auto = (i.autocomplete || '').toLowerCase();
                    const placeholder = (i.placeholder || '').toLowerCase();
                    return auto.includes('username') || auto.includes('email') || auto.includes('tel') ||
                           name.includes('user') || name.includes('login') || name.includes('email') || name.includes('account') || name.includes('phone') || name.includes('mobile') ||
                           id.includes('user') || id.includes('login') || id.includes('email') || id.includes('account') || id.includes('phone') || id.includes('mobile') ||
                           placeholder.includes('账号') || placeholder.includes('用户名') || placeholder.includes('手机') || placeholder.includes('邮箱') ||
                           i.type === 'email' || i.type === 'tel';
                });
                if (cand) return cand;

                // 兜底找在 password 之前最近的一个可见文本输入框
                const passIndex = inputs.indexOf(passInput);
                for (let k = passIndex - 1; k >= 0; k--) {
                    const el = inputs[k];
                    const type = (el.type || '').toLowerCase();
                    if ((type === 'text' || type === 'email' || type === 'tel' || type === '') && !el.disabled && !el.readOnly) {
                        return el;
                    }
                }
                return null;
            }

            function findPasswordInput(userInput) {
                const form = userInput.form || userInput.closest('form') || document;
                const passInputs = Array.from(form.querySelectorAll('input[type="password"]'));
                return passInputs.length > 0 ? passInputs[0] : null;
            }

            function setNativeValue(el, val) {
                if (!el) return;
                if (el.value === val) return;
                // 解决某些 React 受控组件重写 value setter 的问题
                const prototype = Object.getPrototypeOf(el);
                const desc = Object.getOwnPropertyDescriptor(prototype, 'value');
                if (desc && desc.set) {
                    desc.set.call(el, val);
                } else {
                    el.value = val;
                }
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
                // 闪烁高亮提示已自动填写
                const originalBg = el.style.backgroundColor;
                el.style.transition = 'background-color 0.4s ease';
                el.style.backgroundColor = 'rgba(218, 165, 32, 0.15)';
                setTimeout(() => { el.style.backgroundColor = originalBg; }, 1200);
            }

            function fillCredentialPair(username, password) {
                const active = window.__safarierActiveInput || document.activeElement;
                let userInput = null;
                let passInput = null;

                if (active && active.tagName === 'INPUT') {
                    if ((active.type || '').toLowerCase() === 'password') {
                        passInput = active;
                        userInput = findUsernameInput(passInput);
                    } else {
                        userInput = active;
                        passInput = findPasswordInput(userInput);
                    }
                } else {
                    const passList = Array.from(document.querySelectorAll('input[type="password"]'));
                    if (passList.length > 0) {
                        passInput = passList[0];
                        userInput = findUsernameInput(passInput);
                    }
                }

                try {
                    window.__safarierAutofilling = true;
                    if (userInput && username && userInput.value !== username) {
                        setNativeValue(userInput, username);
                    }
                    if (passInput && password && passInput.value !== password) {
                        setNativeValue(passInput, password);
                    }
                } finally {
                    setTimeout(() => { window.__safarierAutofilling = false; }, 300);
                }
            }

            function captureAndNotify(passInput) {
                if (window.__safarierAutofilling) return;
                if (!passInput) return;
                const passVal = passInput.value || '';
                if (!passVal) return;

                const userInput = findUsernameInput(passInput);
                const userVal = userInput ? (userInput.value || '') : '';

                const domain = getDomain();
                if (!domain) return;

                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(messageHandlerName)) {
                    window.webkit.messageHandlers.\(messageHandlerName).postMessage({
                        type: 'credentialsSubmitted',
                        domain: domain,
                        username: userVal,
                        password: passVal
                    });
                }
            }

            // --- 选项下拉框逻辑 ---
            let popupHost = null;
            let currentOptions = [];
            let selectedIndex = -1;

            function dismissPopup() {
                if (popupHost) {
                    try { popupHost.remove(); } catch(e) {}
                    popupHost = null;
                }
                currentOptions = [];
                selectedIndex = -1;
            }
            window.__safarierDismissAutofillPopup = dismissPopup;

            function updateSelection(newIndex) {
                if (!popupHost || !popupHost.shadowRoot) return;
                const items = popupHost.shadowRoot.querySelectorAll('.item');
                if (items.length === 0) return;
                if (selectedIndex >= 0 && selectedIndex < items.length) {
                    items[selectedIndex].classList.remove('selected');
                }
                if (newIndex < 0) newIndex = items.length - 1;
                if (newIndex >= items.length) newIndex = 0;
                selectedIndex = newIndex;
                items[selectedIndex].classList.add('selected');
                items[selectedIndex].scrollIntoView({ block: 'nearest' });
            }

            function escapeHTML(str) {
                return String(str)
                    .replace(/&/g, '&amp;')
                    .replace(/</g, '&lt;')
                    .replace(/>/g, '&gt;')
                    .replace(/"/g, '&quot;');
            }

            window.__safarierShowAutofillOptions = function(options) {
                dismissPopup();
                if (!Array.isArray(options) || options.length === 0) return;

                const target = window.__safarierActiveInput || document.activeElement;
                if (!target || target.tagName !== 'INPUT') return;

                const rect = target.getBoundingClientRect();
                if (rect.width === 0 && rect.height === 0) return;

                currentOptions = options;
                selectedIndex = -1;

                popupHost = document.createElement('div');
                popupHost.id = '__safarier_autofill_container';
                popupHost.style.cssText = 'all: initial !important; position: fixed !important; z-index: 2147483647 !important; pointer-events: auto !important;';

                const shadow = popupHost.attachShadow({ mode: 'open' });
                shadow.innerHTML = `
                    <style>
                        :host {
                            all: initial;
                            display: block;
                            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                            font-size: 13px;
                            line-height: 1.35;
                            user-select: none;
                            -webkit-user-select: none;
                            box-sizing: border-box;
                        }
                        * {
                            box-sizing: border-box;
                        }
                        .dropdown {
                            background: rgba(255, 255, 255, 0.95);
                            color: #1d1d1f;
                            border: 1px solid rgba(0, 0, 0, 0.12);
                            border-radius: 8px;
                            box-shadow: 0 4px 20px rgba(0, 0, 0, 0.15), 0 1px 4px rgba(0, 0, 0, 0.08);
                            backdrop-filter: blur(25px);
                            -webkit-backdrop-filter: blur(25px);
                            padding: 4px;
                            min-width: 220px;
                            max-width: 360px;
                            max-height: 240px;
                            overflow-y: auto;
                            animation: safIn 0.1s ease-out;
                        }
                        @media (prefers-color-scheme: dark) {
                            .dropdown {
                                background: rgba(42, 42, 44, 0.95);
                                color: #f5f5f7;
                                border: 1px solid rgba(255, 255, 255, 0.16);
                                box-shadow: 0 4px 24px rgba(0, 0, 0, 0.45), 0 1px 4px rgba(0, 0, 0, 0.25);
                            }
                        }
                        @keyframes safIn {
                            from { opacity: 0; transform: translateY(-3px); }
                            to { opacity: 1; transform: translateY(0); }
                        }
                        .header {
                            font-size: 11px;
                            font-weight: 600;
                            color: #86868b;
                            padding: 4px 8px 3px;
                            letter-spacing: 0.3px;
                            border-bottom: 1px solid rgba(0, 0, 0, 0.06);
                            margin-bottom: 2px;
                        }
                        @media (prefers-color-scheme: dark) {
                            .header {
                                border-bottom-color: rgba(255, 255, 255, 0.08);
                                color: #a1a1a6;
                            }
                        }
                        .item {
                            display: flex;
                            align-items: center;
                            gap: 8px;
                            padding: 6px 8px;
                            border-radius: 6px;
                            cursor: pointer;
                            transition: background-color 0.08s ease;
                        }
                        .item:hover, .item.selected {
                            background-color: #007aff;
                            color: #ffffff;
                        }
                        .item:hover .subtext, .item.selected .subtext {
                            color: rgba(255, 255, 255, 0.82);
                        }
                        .icon {
                            display: flex;
                            align-items: center;
                            justify-content: center;
                            width: 18px;
                            height: 18px;
                            flex-shrink: 0;
                            color: inherit;
                        }
                        .content {
                            flex: 1;
                            min-width: 0;
                            overflow: hidden;
                        }
                        .username {
                            font-weight: 500;
                            white-space: nowrap;
                            overflow: hidden;
                            text-overflow: ellipsis;
                        }
                        .subtext {
                            font-size: 11px;
                            color: #86868b;
                            white-space: nowrap;
                            overflow: hidden;
                            text-overflow: ellipsis;
                            margin-top: 1px;
                        }
                    </style>
                    <div class="dropdown">
                        <div class="header">自动填充密码</div>
                        <div class="items"></div>
                    </div>
                `;

                const itemsContainer = shadow.querySelector('.items');
                options.forEach(opt => {
                    const item = document.createElement('div');
                    item.className = 'item';
                    item.innerHTML = `
                        <div class="icon">
                            <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor">
                                <path d="M7 14c-2.76 0-5-2.24-5-5s2.24-5 5-5c2.42 0 4.44 1.72 4.9 4H22v4h-2v2h-2v-2h-2v2h-2v-2h-2.1c-.46 2.28-2.48 4-4.9 4zm0-8C5.34 6 4 7.34 4 9s1.34 3 3 3 3-1.34 3-3-1.34-3-3-3z"/>
                            </svg>
                        </div>
                        <div class="content">
                            <div class="username">${escapeHTML(opt.username || '未命名账号')}</div>
                            <div class="subtext">•••••••• · Safarier</div>
                        </div>
                    `;
                    item.addEventListener('mousedown', function(e) {
                        e.preventDefault();
                        e.stopPropagation();
                        fillCredentialPair(opt.username, opt.password);
                        dismissPopup();
                    });
                    itemsContainer.appendChild(item);
                });

                document.documentElement.appendChild(popupHost);

                const dropdown = shadow.querySelector('.dropdown');
                const dropdownWidth = Math.max(rect.width, 220);
                const dropdownHeight = dropdown.offsetHeight || (30 + options.length * 40);
                const margin = 4;

                let left = rect.left;
                if (left + dropdownWidth > window.innerWidth - 8) {
                    left = Math.max(8, window.innerWidth - dropdownWidth - 8);
                }
                if (left < 8) left = 8;

                let top = rect.bottom + margin;
                if (top + dropdownHeight > window.innerHeight - 8) {
                    if (rect.top - dropdownHeight - margin > 8) {
                        top = rect.top - dropdownHeight - margin;
                    } else {
                        top = Math.max(8, window.innerHeight - dropdownHeight - 8);
                    }
                }

                popupHost.style.top = top + 'px';
                popupHost.style.left = left + 'px';
                popupHost.style.width = dropdownWidth + 'px';
            };

            // 监听输入框获得焦点/点击事件（用户点击账号框或密码框时请求显示自动填充选项）
            function handleFieldFocus(e) {
                if (window.__safarierAutofilling) return;
                const target = e.target;
                if (!target || target.tagName !== 'INPUT') return;
                const type = (target.type || '').toLowerCase();
                if (type !== 'password' && type !== 'text' && type !== 'email' && type !== 'tel' && type !== '') return;

                // 仅在存在密码输入框的登录/注册表单中触发
                const form = target.form || target.closest('form') || document;
                const passInputs = Array.from(form.querySelectorAll('input[type="password"]'));
                if (passInputs.length === 0) return;

                if (popupHost && window.__safarierActiveInput === target) return;

                window.__safarierActiveInput = target;

                const domain = getDomain();
                if (!domain) return;

                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(messageHandlerName)) {
                    window.webkit.messageHandlers.\(messageHandlerName).postMessage({
                        type: 'fieldFocused',
                        domain: domain
                    });
                }
            }

            document.addEventListener('focusin', handleFieldFocus, true);
            document.addEventListener('click', handleFieldFocus, true);

            // 监听键盘按键：Escape 关闭，ArrowDown/ArrowUp 切换，Enter 确认填充
            document.addEventListener('keydown', function(e) {
                if (!popupHost) return;
                if (e.key === 'Escape') {
                    e.preventDefault();
                    e.stopPropagation();
                    dismissPopup();
                } else if (e.key === 'ArrowDown') {
                    e.preventDefault();
                    e.stopPropagation();
                    updateSelection(selectedIndex + 1);
                } else if (e.key === 'ArrowUp') {
                    e.preventDefault();
                    e.stopPropagation();
                    updateSelection(selectedIndex - 1);
                } else if (e.key === 'Enter') {
                    if (selectedIndex >= 0 && selectedIndex < currentOptions.length) {
                        e.preventDefault();
                        e.stopPropagation();
                        const opt = currentOptions[selectedIndex];
                        fillCredentialPair(opt.username, opt.password);
                        dismissPopup();
                    }
                }
            }, true);

            // 点击外部关闭弹窗
            document.addEventListener('mousedown', function(e) {
                if (!popupHost) return;
                const path = e.composedPath ? e.composedPath() : [];
                if (path.includes(popupHost) || e.target === window.__safarierActiveInput) {
                    return;
                }
                dismissPopup();
            }, true);

            // 用户开始手动输入时，关闭弹窗以免遮挡输入
            document.addEventListener('input', function() {
                if (!window.__safarierAutofilling) {
                    dismissPopup();
                }
            }, true);

            // 滚动或窗口缩放、窗口失焦时关闭弹窗
            window.addEventListener('scroll', function() {
                dismissPopup();
            }, true);
            window.addEventListener('resize', function() {
                dismissPopup();
            }, true);
            window.addEventListener('blur', function() {
                dismissPopup();
            }, true);

            // 监听表单 submit 事件
            document.addEventListener('submit', function(e) {
                if (window.__safarierAutofilling) return;
                const form = e.target;
                if (!form || !form.querySelectorAll) return;
                const passInputs = Array.from(form.querySelectorAll('input[type="password"]'));
                if (passInputs.length > 0) {
                    captureAndNotify(passInputs[0]);
                }
            }, true);

            // 监听点击提交按钮
            document.addEventListener('click', function(e) {
                if (window.__safarierAutofilling) return;
                const target = e.target;
                if (!target || !target.closest) return;
                const btn = target.closest('button, input[type="submit"]');
                if (btn) {
                    const btnType = (btn.getAttribute('type') || (btn.tagName === 'BUTTON' ? 'submit' : '')).toLowerCase();
                    if (btnType !== 'submit') return;
                    const form = btn.form || btn.closest('form') || document;
                    const passInputs = Array.from(form.querySelectorAll('input[type="password"]'));
                    if (passInputs.length > 0) {
                        captureAndNotify(passInputs[0]);
                    }
                }
            }, true);
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageHandlerName, let dict = message.body as? [String: Any], let type = dict["type"] as? String else {
            return
        }

        switch type {
        case "credentialsSubmitted":
            guard let domain = dict["domain"] as? String,
                  let pass = dict["password"] as? String, !pass.isEmpty else { return }
            let user = (dict["username"] as? String) ?? ""
            delegate?.formAutofillBridge(self, didSubmitCredentials: domain, username: user, password: pass)

        default:
            break
        }
    }

    // MARK: - 原生向页面填充凭据

    /// 在网页当前活跃的输入框下方显示可用凭据选项下拉框
    static func showAutofillOptions(in webView: WKWebView, credentials: [WebCredential]) {
        struct CredentialOption: Encodable {
            let id: String
            let username: String
            let password: String
        }
        let options = credentials.map { CredentialOption(id: $0.id.uuidString, username: $0.username, password: $0.password) }
        guard let jsonData = try? JSONEncoder().encode(options),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        let safeJSON = jsonString
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")

        let script = "window.__safarierShowAutofillOptions && window.__safarierShowAutofillOptions(\(safeJSON));"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// 自动填写账号密码并触发 DOM input/change 事件以适配现代前端框架 (React/Vue/Angular等)
    static func fillCredentials(in webView: WKWebView, credential: WebCredential, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard let userJSON = try? String(data: JSONEncoder().encode(credential.username), encoding: .utf8),
              let passJSON = try? String(data: JSONEncoder().encode(credential.password), encoding: .utf8) else {
            completion?(false)
            return
        }

        let script = """
        (function() {
            const userVal = \(userJSON);
            const passVal = \(passJSON);

            const passwords = Array.from(document.querySelectorAll('input[type="password"]'));
            if (passwords.length === 0) return false;

            const passInput = passwords[0];
            const form = passInput.form || passInput.closest('form') || document;
            const inputs = Array.from(form.querySelectorAll('input'));

            let userInput = inputs.find(i => {
                if (i.type === 'password' || i.type === 'hidden' || i.type === 'submit' || i.type === 'button') return false;
                const name = (i.name || '').toLowerCase();
                const id = (i.id || '').toLowerCase();
                const auto = (i.autocomplete || '').toLowerCase();
                const placeholder = (i.placeholder || '').toLowerCase();
                return auto.includes('username') || auto.includes('email') || auto.includes('tel') ||
                       name.includes('user') || name.includes('login') || name.includes('email') || name.includes('account') || name.includes('phone') || name.includes('mobile') ||
                       id.includes('user') || id.includes('login') || id.includes('email') || id.includes('account') || id.includes('phone') || id.includes('mobile') ||
                       placeholder.includes('账号') || placeholder.includes('用户名') || placeholder.includes('手机') || placeholder.includes('邮箱') ||
                       i.type === 'email' || i.type === 'tel';
            });

            if (!userInput) {
                const passIndex = inputs.indexOf(passInput);
                for (let k = passIndex - 1; k >= 0; k--) {
                    const el = inputs[k];
                    const type = (el.type || '').toLowerCase();
                    if ((type === 'text' || type === 'email' || type === 'tel' || type === '') && !el.disabled && !el.readOnly) {
                        userInput = el;
                        break;
                    }
                }
            }

            function setNativeValue(el, val) {
                if (!el) return;
                if (el.value === val) return;
                // 解决某些 React 受控组件重写 value setter 的问题
                const prototype = Object.getPrototypeOf(el);
                const desc = Object.getOwnPropertyDescriptor(prototype, 'value');
                if (desc && desc.set) {
                    desc.set.call(el, val);
                } else {
                    el.value = val;
                }
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
                // 闪烁高亮提示已自动填写
                const originalBg = el.style.backgroundColor;
                el.style.transition = 'background-color 0.4s ease';
                el.style.backgroundColor = 'rgba(218, 165, 32, 0.15)';
                setTimeout(() => { el.style.backgroundColor = originalBg; }, 1200);
            }

            try {
                window.__safarierAutofilling = true;
                let didFill = false;
                if (userInput && userVal && userInput.value !== userVal) {
                    setNativeValue(userInput, userVal);
                    didFill = true;
                }
                if (passInput && passVal && passInput.value !== passVal) {
                    setNativeValue(passInput, passVal);
                    didFill = true;
                }
                return didFill;
            } finally {
                setTimeout(() => { window.__safarierAutofilling = false; }, 300);
            }
        })();
        """

        webView.evaluateJavaScript(script) { result, _ in
            let filled = (result as? Bool) ?? false
            completion?(filled)
        }
    }
}
