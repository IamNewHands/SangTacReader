import UIKit
import WebKit

class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

    var webView: WKWebView!

    // ===== 全屏沉浸阅读页 (v13) =====
    // 章节页正文提取后，用独立 WKWebView 渲染正文 HTML，提供 App 级阅读体验。
    private var readerView: WKWebView!
    private var readerContainer: UIView!
    private var readerTitleLabel: UILabel!
    private var readerLastData: (h: String, bookid: String, c: String)? = nil
    private var readerExpectedC: String? = nil   // 用户期望的当前章节 ID，过滤章节页迟到/重复上报
    private var readerLoadedC: String? = nil     // 阅读页已显示的章节 ID
    private let readerTopBarHeight: CGFloat = 52

    private var cookieObserver: CookieObserver?
    // ===== 临时调试日志面板 (debug-point D) =====
    // 无 Xcode 控制台访问时，把 [DBG:] 日志直接显示在 iOS 界面，供用户复制。
    private var debugLogs: [String] = []
    private var logTextView: UITextView!
    private var logToggleButton: UIButton!
    private var logPanelVisible = false
    private let maxLogLines = 600

    // iOS 纯 Web 模式方案（参考安卓，但不用 WKURLSchemeHandler 接管 https——那会抛异常，
    // 因为 https 是 WKWebView 原生自带的 scheme）：
    // 服务器要求 GET 请求必须携带 Referer 头，否则返回空体(Content-Length: 0)，
    // 前端会误判为 "Kết nối tới máy chủ thất bại"。
    // JS 无法通过 XHR 设置 Referer(forbidden header)，但 WKWebView 对【同源】XHR
    // 会自动携带完整 Referer。因此注入脚本强制所有 STV 请求保持同源(不切镜像域名)，
    // 让浏览器自动带上 Referer，等价于安卓 CapacitorHttp 显式附加 Referer 的效果。

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupWebView()
        setupCookiePersistence()
        restorePersistedCookies()
        loadApp()
        setupDebugPanel()
    }

    // ===== Cookie 手动持久化 (LiveContainer 下 WKWebsiteDataStore.default()
    //      持久化不可靠，登录后的 access/useri2 等关键 cookie 冷启动即丢失，
    //      导致 readchapter 服务器返回 code:7 "设备不支持/版本过旧"。=====
    private static let cookieDefaultsKey = "stv.persistedCookies.v1"

    // 用 Codable 结构体序列化 cookie，避免 NSKeyedArchiver 对 HTTPCookie
    // 数组的归档在部分 SDK 上的编译/运行时兼容问题。
    private struct PersistedCookie: Codable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var secure: Bool
        var httpOnly: Bool
        var expires: Date?
    }

    private func setupCookiePersistence() {
        guard let store = webView?.configuration.websiteDataStore.httpCookieStore else { return }
        // 先创建 observer 再 add，避免把 Optional 传给 add(_:)
        let observer = CookieObserver(owner: self)
        cookieObserver = observer
        store.add(observer)
    }

    private func restorePersistedCookies() {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: WebViewController.cookieDefaultsKey),
              let items = try? JSONDecoder().decode([PersistedCookie].self, from: data) else { return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for item in items {
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: item.name,
                .value: item.value,
                .domain: item.domain,
                .path: item.path,
            ]
            if item.secure { props[.secure] = "TRUE" }
            if item.httpOnly { props[HTTPCookiePropertyKey(rawValue: "HttpOnly")] = "TRUE" }
            if let e = item.expires { props[.expires] = e }
            if let c = HTTPCookie(properties: props) {
                store.setCookie(c, completionHandler: nil)
            }
        }
        appendDebugLog("[cookie] restored \(items.count) cookies")
    }

    // fileprivate：被同文件的 CookieObserver 回调调用
    fileprivate func saveCookies() {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { cookies in
            let items = cookies.map { c -> PersistedCookie in
                PersistedCookie(name: c.name, value: c.value, domain: c.domain,
                                path: c.path, secure: c.isSecure,
                                httpOnly: c.isHTTPOnly, expires: c.expiresDate)
            }
            guard let data = try? JSONEncoder().encode(items) else { return }
            UserDefaults.standard.set(data, forKey: WebViewController.cookieDefaultsKey)
        }
    }

    // ===== 临时调试日志面板 UI (debug-point D) =====
    private func setupDebugPanel() {
        // 显示/隐藏日志的悬浮开关（右上角），避免遮挡正常 UI
        logToggleButton = UIButton(type: .system)
        logToggleButton.setTitle("LOG", for: .normal)
        logToggleButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
        logToggleButton.setTitleColor(.white, for: .normal)
        logToggleButton.backgroundColor = UIColor(white: 0, alpha: 0.55)
        logToggleButton.layer.cornerRadius = 14
        logToggleButton.layer.masksToBounds = true
        logToggleButton.addTarget(self, action: #selector(toggleLogPanel), for: .touchUpInside)
        logToggleButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(logToggleButton)

        // 日志展示面板（半透明覆盖层）
        logTextView = UITextView()
        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.backgroundColor = UIColor(white: 0.08, alpha: 0.92)
        logTextView.textColor = .white
        logTextView.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logTextView.text = "等待日志..."
        logTextView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(logTextView)

        let copyButton = UIButton(type: .system)
        copyButton.setTitle("复制日志", for: .normal)
        copyButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
        copyButton.setTitleColor(.white, for: .normal)
        copyButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
        copyButton.layer.cornerRadius = 12
        copyButton.layer.masksToBounds = true
        copyButton.addTarget(self, action: #selector(copyLogs), for: .touchUpInside)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(copyButton)

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("隐藏", for: .normal)
        closeButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.backgroundColor = UIColor(white: 0.25, alpha: 0.85)
        closeButton.layer.cornerRadius = 12
        closeButton.layer.masksToBounds = true
        closeButton.addTarget(self, action: #selector(toggleLogPanel), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            logToggleButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            logToggleButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            logToggleButton.widthAnchor.constraint(equalToConstant: 52),
            logToggleButton.heightAnchor.constraint(equalToConstant: 28),

            logTextView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            logTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            logTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            logTextView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.6),

            copyButton.topAnchor.constraint(equalTo: logTextView.bottomAnchor, constant: 6),
            copyButton.trailingAnchor.constraint(equalTo: logTextView.trailingAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 110),
            copyButton.heightAnchor.constraint(equalToConstant: 36),

            closeButton.topAnchor.constraint(equalTo: logTextView.bottomAnchor, constant: 6),
            closeButton.leadingAnchor.constraint(equalTo: logTextView.leadingAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 90),
            closeButton.heightAnchor.constraint(equalToConstant: 36)
        ])

        logTextView.isHidden = true
        copyButton.isHidden = true
        closeButton.isHidden = true
    }

    @objc private func toggleLogPanel() {
        logPanelVisible.toggle()
        logTextView.isHidden = !logPanelVisible
        logToggleButton.superview?.subviews.forEach { v in
            if v is UIButton && v !== logToggleButton {
                v.isHidden = !logPanelVisible
            }
            if v is UITextView {
                v.isHidden = !logPanelVisible
            }
        }
        if logPanelVisible {
            refreshLogView(forceScroll: true)
        }
    }

    @objc private func copyLogs() {
        let text = logTextView.text ?? ""
        UIPasteboard.general.string = text
        showToast("已复制 \(debugLogs.count) 条日志")
    }

    private func showToast(_ msg: String) {
        let label = UILabel()
        label.text = msg
        label.textColor = .white
        label.backgroundColor = UIColor(white: 0, alpha: 0.8)
        label.font = UIFont.systemFont(ofSize: 13)
        label.textAlignment = .center
        label.layer.cornerRadius = 8
        label.layer.masksToBounds = true
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            label.heightAnchor.constraint(equalToConstant: 40)
        ])
        UIView.animate(withDuration: 0.25, animations: { label.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.5, delay: 1.2, options: [], animations: { label.alpha = 0 }) { _ in
                label.removeFromSuperview()
            }
        }
    }

    private func appendDebugLog(_ line: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        debugLogs.append("[\(ts)] \(line)")
        if debugLogs.count > maxLogLines {
            debugLogs.removeFirst(debugLogs.count - maxLogLines)
        }
        // 同时打印到控制台（有 Xcode 时也能看）
        print(line)
        refreshLogView(forceScroll: false)
    }

    private func refreshLogView(forceScroll: Bool) {
        guard logTextView != nil else { return }
        if logPanelVisible {
            let shouldScroll = forceScroll || isNearBottom(logTextView)
            logTextView.text = debugLogs.joined(separator: "\n")
            if shouldScroll {
                let range = NSRange(location: (logTextView.text as NSString).length, length: 0)
                logTextView.scrollRangeToVisible(range)
            }
        }
    }

    private func isNearBottom(_ tv: UITextView) -> Bool {
        let offset = tv.contentOffset.y + tv.bounds.size.height
        return tv.contentSize.height - offset < 120
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()

        // 允许 Cookie 和本地持久化
        config.websiteDataStore = WKWebsiteDataStore.default()

        // 注入 iOS WebKit CSS 视口与安全区规则 (纯 Web 模式，不注入任何原生桥接)。
        // 关键：前端 app.v2.js 通过检查全局 Capacitor 对象是否存在于 window 上来判断是否原生模式，
        // 一旦存在该对象，前端就会等待原生 SQLite 数据库，导致 app.init() 永不执行。
        // 因此此处只做 CSS 修复，让前端进入正常的 Web 分支 (localStorage + XHR)。)
        let bridgeJS = """
        (function() {
            // ===== iOS 章节读取修复 v8.1：章节页(/truyen/)完全不加插桩 =====
            // 章节正文的 web readchapter 依赖页面自身混淆脚本包裹 XHR.send 注入反爬证明
            // (gac/state proof)；任何外部对 XHR.open/send 的覆写都可能被其检测并导致
            // readchapter 返回 code:7 -> 页面无限 location.reload()。因此当主框架是章节页
            // 时，本脚本直接空转，让章节页与真实浏览器运行环境完全一致。
            try {
                if (String(window.location.pathname).indexOf('/truyen/') === 0) { return; }
            } catch(e) {}

            // ===== iOS 章节读取修复 v7：注入 Capacitor.Plugins.Http + key 机制 =====
            // 已从 app.v2.read.js 源码 + 服务器实测确认真相：
            //   1) readchapter 必须带 key（服务器对无 key 的请求返回 {"code":7}）。
            //      前端 getContent/getContent2 构造：
            //        /?sajax=readchapter&h={h}&bookid={i}&c={c}&key=${this.chapterkey}
            //   2) chapterkey 由 app.reader.loadKeyFromServer 获取：它仅在
            //      window.Capacitor.Plugins.Http 存在时运行，通过该插件 GET
            //      /io/grantcontext/context?hostid=&bookid= 拿到一段混淆 JS，
            //      再 this.chapterkey = eval(混淆JS) 生成 key。
            //   3) 该混淆 JS 依赖 window.Capacitor / window.Engine 等存在做环境指纹，
            //      只在真实浏览器 WebView 里 eval 才能生成有效 key。
            //
            // 因此本修复：注入一个仅含 Plugins.Http（底层用原生 XHR 实现）的极简
            // Capacitor，且【不设置 getPlatform】，让 app.platform.isIOS 保持 false、
            // 页面布局维持纯 Web 模式（避免之前"注入 Capacitor 后点不了"的塌陷）。
            // 这样原版 loadKeyFromServer 能运行、eval 在真实 WKWebView 里生成 key。
            function tryDbg(tag, msg) {
                try {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dbg) {
                        window.webkit.messageHandlers.dbg.postMessage({tag: tag, msg: String(msg)});
                        return;
                    }
                } catch(e) {}
                try { console.log('[key:' + tag + '] ' + msg); } catch(e) {}
            }
            // 用原生 XHR 模拟 Capacitor.Http.get（iOS 无 Capacitor，原实现不工作）。
            // 服务器要求 readchapter 必须带 key；key 由 /io/grantcontext/context 下发的一段
            // 混淆 JS 经 eval 生成（见 app.v2.read.js 的 loadKeyFromServer/getContent2）。
            function patchReaderGetContent(app) {
                try {
                    if (!app || !app.reader) return false;
                    if (app.reader.__getContentPatched) return true;
                    app.reader.__getContentPatched = true;
                    var origLoadKey = app.reader.loadKeyFromServer;
                    var origGetContent = app.reader.getContent;
                    // 覆写 loadKeyFromServer：用 XHR 拉取混淆 JS 并 eval 得到 chapterkey。
                    // 复刻 App 端：带 "mac_tt=true" cookie 后缀 + app 传输头。
                    app.reader.loadKeyFromServer = async function(h, i) {
                        try {
                            var base = window.location.origin;
                            var ctxUrl = base + "/io/grantcontext/context?hostid=" + encodeURIComponent(h) + "&bookid=" + encodeURIComponent(i);
                            tryDbg('gkey-url', ctxUrl);
                            var js = await new Promise(function(resolve, reject) {
                                var xhr = new XMLHttpRequest();
                                xhr.open("GET", ctxUrl, true);
                                // 追加 mac_tt=true（服务器校验该 cookie 后缀）
                                if (document.cookie && document.cookie.indexOf("mac_tt=") < 0) {
                                    xhr.setRequestHeader("Cookie", document.cookie + "; mac_tt=true;");
                                }
                                xhr.setRequestHeader("x-stv-transport", "app");
                                xhr.setRequestHeader("x-requested-with", "com.sangtacviet.mobilereader");
                                xhr.onreadystatechange = function() {
                                    if (xhr.readyState === 4) {
                                        if (xhr.status === 200) resolve(xhr.responseText);
                                        else reject(new Error("ctx status " + xhr.status));
                                    }
                                };
                                xhr.onerror = function() { reject(new Error("ctx xhr error")); };
                                xhr.send();
                            });
                            tryDbg('gkey-js-len', 'len=' + (js ? js.length : 0));
                            var key = eval(js); // 服务器下发混淆 JS，eval 得到 chapterkey
                            tryDbg('gkey', 'key=' + String(key));
                            this.chapterkey = key;
                            return key;
                        } catch(e) {
                            tryDbg('gkey-err', 'exception: ' + e);
                            // 取 key 失败时回退到原实现
                            return origLoadKey.apply(this, arguments);
                        }
                    };
                    // 覆写 getContent（v13）：整页导航到章节页建立 time:30 会话。
                    // 根因（v12 实验证实）：SPA 内同源 XHR 发 readchapter 恒返回
                    // {"code":7,"time":1000}（非浏览器环境），无论 body/cookie/proof 怎么变；
                    // 只有整页导航加载章节页(/truyen/)才能建立 time:30 的"浏览器页面"会话，
                    // 从而让空 body readchapter 走 code:21 -> verifyca -> code:0（见 log8）。
                    // 因此原生阅读的正确路径 = 先整页导航章节页拿正文，再由原生阅读页渲染。
                    app.reader.getContent = async function(h, i, c, rl) {
                        var self = this;
                        if (self.offlineBook && !rl) {
                            try { var cdata = await self.offlineBook.getChapterOrNull(c); if (cdata) return JSON.parse(cdata); } catch(e) {}
                        }
                        try { self.setTransMode(); } catch(e) {}
                        tryDbg('gc', 'h=' + h + ' i/bookid=' + i + ' c=' + c + ' rl=' + rl);
                        var base = window.location.origin;
                        // 整页导航到章节页（建立会话 + 触发 verifyca 验证）
                        var chapUrl = base + "/truyen/" + encodeURIComponent(h) + "/1/" + encodeURIComponent(i) + "/" + encodeURIComponent(c) + "/";
                        tryDbg('gc-nav', 'navigating to ' + chapUrl);
                        // 记录待读章节，供章节页提取脚本 + 原生阅读器回退使用
                        try { window.__stvPendingRead = {h:h, bookid:i, c:c}; } catch(e) {}
                        setTimeout(function() { try { window.location.href = chapUrl; } catch(e) {} }, 150);
                        return {code: "1", info: "正在进入阅读器…"};
                    };
                    return true;
                } catch(e) { return false; }
            }
            // 定时尝试在 app.reader 可用后覆写（app.v2.read.js 由 ui.scriptmanager 动态加载）
            (function() {
                function apply() {
                    try {
                        if (typeof window.app !== 'undefined' && window.app && window.app.reader) {
                            if (patchReaderGetContent(window.app)) {
                                clearInterval(t);
                                clearTimeout(stopper);
                            }
                        }
                    } catch(e) {}
                }
                var t = setInterval(apply, 300);
                var stopper = setTimeout(function() { clearInterval(t); }, 20000);
                apply();
            })();
            // 闭合最外层 (function() {（第 257 行）。此前该外层 IIFE 缺少闭合括号，
            // 导致整个 bridgeJS 的 JS 语法错误、一行都不执行。这是此前所有注入
            // 补丁从未生效的直接原因之一（另一处是字符串里的反斜杠 n 被 Swift 转义）。
            })();

            var css = document.createElement('style');
            css.id = 'ios-viewport-fix';
            css.innerHTML = `
                :root {
                    --vh: 1vh;
                    --vh100: 100vh;
                    --vh100subtop: 100vh;
                    --status-bar-height: env(safe-area-inset-top, 0px);
                    --screensafebottom: env(safe-area-inset-bottom, 0px);
                }
                tab#mainview {
                    height: 100vh !important;
                    height: 100dvh !important;
                }
                #mainnavbar {
                    padding-bottom: env(safe-area-inset-bottom, 0px);
                }
            `;
            if (document.head) {
                document.head.appendChild(css);
            } else {
                document.addEventListener('DOMContentLoaded', function() {
                    document.head.appendChild(css);
                });
            }

            function updateVH() {
                var vh = (window.innerHeight || document.documentElement.clientHeight) * 0.01;
                document.documentElement.style.setProperty('--vh', vh + 'px');
                document.documentElement.style.setProperty('--vh100', (window.innerHeight || document.documentElement.clientHeight) + 'px');
                document.documentElement.style.setProperty('--vh100subtop', (window.innerHeight || document.documentElement.clientHeight) + 'px');
            }
            updateVH();
            window.addEventListener('resize', updateVH);
            window.addEventListener('orientationchange', updateVH);

            // iOS 纯 Web 模式：强制 STV 请求保持同域，绕开跨域 CORS preflight 拦截。
            // 原因：前端 fullUrl()/bestDomain() 会把登录/源目录请求切到镜像域名
            // (sangtacviet.com / dns1.stv-appdomain-00000001.org / sangtacviet.app)。
            // 这些 GET 请求都带自定义头 x-stv-transport: web（服务器要求，去掉会返回 502），
            // 而服务器 CORS 白名单 (Access-Control-Allow-Headers) 不包含 x-stv-transport，
            // 导致跨域 preflight 被拦截 -> XHR onerror -> "Kết nối tới máy chủ thất bại"。
            // 把请求改回当前页面域后变成同域请求，无 preflight，x-stv-transport 头正常发送，
            // 且 WKWebView 对【同源】XHR 会自动携带完整 Referer（满足服务器强制要求，
            // 等价于安卓 CapacitorHttp 显式附加 Referer）。
            (function() {
                try {
                    var curOrigin = window.location.origin;
                    var stvHosts = [
                        'sangtacviet.com',
                        'sangtacviet.app',
                        'sangtacviet.vip',
                        'dns1.stv-appdomain-00000001.org'
                    ];
                    var origOpen = XMLHttpRequest.prototype.open;
                    XMLHttpRequest.prototype.open = function(method, url) {
                        try {
                            var args = Array.prototype.slice.call(arguments);
                            if (typeof url === 'string') {
                                var curOrigin = window.location.origin;
                                // 相对路径补全为绝对同源 URL
                                if (url.indexOf('://') === -1) {
                                    url = curOrigin + (url.charAt(0) === '/' ? url : '/' + url);
                                }
                                var u = new URL(url, window.location.href);
                                // 强制 STV 域名请求回到当前同源，让 WKWebView 自动携带 Referer
                                if (stvHosts.indexOf(u.hostname) !== -1 && u.origin !== curOrigin) {
                                    url = curOrigin + u.pathname + u.search;
                                    u = new URL(url, window.location.href);
                                }
                                // readchapter 请求规范化（v7）：保留 App 格式 URL 原样。
                                // 自定义 getContent 已构造 /?sajax=readchapter&h=&bookid=&c=&key=...。
                                // 这里不再添加 ngmar/sty/exts（那是网页章节页格式，与 App 格式冲突）。
                                // 仅清理 eval 失败残留的字面量 key=undefined。
                                if (url.indexOf('readchapter') > -1) {
                                    var sp = u.searchParams;
                                    if (sp.get('key') === 'undefined') sp.delete('key');
                                    u.search = sp.toString();
                                    url = u.toString();
                                }
                                args[1] = url;
                            }
                        } catch (e) {}
                        return origOpen.apply(this, args);
                    };
                } catch (e) {}
            })();

            // 从源头强制保持同源：覆盖 networkManager 与 networkManagerXHR 的域存活判断与
            // bestDomain，让 fullUrl()/getCapacitor 不再把请求切到镜像域名，从而请求从一开始
            // 就是同源的完整 URL，WKWebView 会自动携带完整 Referer。
            // 纯 Web 模式下 fullUrl() 用 networkManagerXHR，login/书卡等用 networkManager，
            // 因此两个对象都要覆盖，避免切到镜像域触发跨域 CORS preflight 拦截。
            (function() {
                try {
                    var applied = false;
                    function patchNet(nm) {
                        if (!nm) return;
                        var curOrigin = window.location.origin;
                        nm.isDomainAlive = function(domain) {
                            try {
                                if (domain === curOrigin) return true;
                            } catch (e) {}
                            return false;
                        };
                        nm.bestDomain = function() {
                            return curOrigin;
                        };
                    }
                    function applyPatch() {
                        try {
                            if (typeof window.app !== 'undefined' &&
                                window.app && window.app.net) {
                                patchNet(window.app.net.networkManager);
                                patchNet(window.app.net.networkManagerXHR);
                                applied = true;
                            }
                        } catch (e) {}
                    }
                    if (typeof document.addEventListener === 'function') {
                        document.addEventListener('DOMContentLoaded', function() { applyPatch(); });
                    }
                    var t = window.setInterval(applyPatch, 300);
                    window.setTimeout(function() { window.clearInterval(t); }, 15000);
                } catch (e) {}
            })();

        // ===== 登录框闪退诊断 (debug-login) =====
        (function(){
            function dl(tag, msg){
                try{
                    if(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dbg){
                        window.webkit.messageHandlers.dbg.postMessage({tag:'lg:'+tag, msg:String(msg)});
                    }
                }catch(e){}
            }
            // 全局 JS 异常：登录框闪退常由脚本异常触发页面回退
            window.addEventListener('error', function(e){
                dl('jserr', (e.message||'') + ' @' + (e.filename||'') + ':' + (e.lineno||''));
            });
            window.addEventListener('unhandledrejection', function(e){
                var r = e.reason; var m = (r && r.message) ? r.message : String(r);
                dl('reject', m);
            });
            var curHash = location.hash;
            window.addEventListener('hashchange', function(){
                dl('hash', curHash + ' => ' + location.hash);
                curHash = location.hash;
            });
            function patchNav(){
                try{
                    if(!window.app) return false;
                    if(window.app.__navPatched) return true;
                    window.app.__navPatched = true;
                    var A = window.app;
                    if(typeof A.pushPage === 'function'){
                        var op = A.pushPage;
                        A.pushPage = function(id, data, cb){
                            var isLogin = (String(id).indexOf('login') > -1);
                            dl('push', 'id=' + id + (isLogin ? ' <== LOGIN' : '') + ' hash=' + location.hash);
                            var r = op.apply(this, arguments);
                            if(isLogin){
                                dl('login-PUSH', 'href=' + location.href);
                                setTimeout(function(){
                                    var tp = (A.topPage ? A.topPage() : null);
                                    dl('login+300ms', 'top=' + (tp ? (tp.view || tp.id || tp.tagName || '?') : 'null') + ' hash=' + location.hash);
                                }, 300);
                                setTimeout(function(){
                                    var tp = (A.topPage ? A.topPage() : null);
                                    dl('login+1500ms', 'top=' + (tp ? (tp.view || tp.id || tp.tagName || '?') : 'null') + ' hash=' + location.hash);
                                }, 1500);
                            }
                            return r;
                        };
                    }
                    if(typeof A.popPage === 'function'){
                        var oq = A.popPage;
                        A.popPage = function(){
                            dl('pop', 'hash=' + location.hash + '\\n' + (new Error().stack||'').split('\\n').slice(1,5).join('\\n'));
                            return oq.apply(this, arguments);
                        };
                    }
                    return true;
                }catch(e){ dl('patchNav-err', String(e)); return false; }
            }
            (function(){
                var t = setInterval(function(){
                    try{ if(patchNav()){ clearInterval(t); } }catch(e){}
                }, 300);
                setTimeout(function(){ clearInterval(t); }, 20000);
            })();
        })();
        """
        // forMainFrameOnly=true：只在主框架注入，避免污染第三方/Cloudflare Turnstile 挑战 iframe。
        // 关键：章节正文的 web readchapter 受 Cloudflare Turnstile 保护；若我们的桥接脚本注入到
        // challenges.cloudflare.com 的挑战 iframe 里并覆写其 XHR，会让 Turnstile 挑战无法完成，
        // cf_clearance 永不签发，readchapter 因此返回 code:7 -> 页面无限 location.reload()。
        let bridgeScript = WKUserScript(source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        controller.addUserScript(bridgeScript)

        // ===== 章节页(/truyen/)正文提取脚本 (v13.1) =====
        // 整页导航到章节页建立 time:30 会话后，正文由章节页自带逻辑异步加载(readchapter code:0)
        // 渲染进 DOM。本脚本【只读】轮询正文容器，提取 HTML+标题+章节信息，postMessage 给 Swift，
        // 供全屏沉浸阅读页渲染。关键：绝不覆写 XHR.open/send（章节页反爬会检测外部覆写导致 code:7）。
        // v13.1 修复：v13 提取到的是"点击加载/正在加载"占位 HTML（readchapter code:0 之前），
        // 不是真正正文。改进：① 正文容器优先；② 就绪判定排除占位符、要求含正文段落 <p>；
        //   ③ 持续轮询直到正文真正就绪（不因容器非空就停）。
        let chapterExtractJS = """
        (function() {
            if (String(window.location.pathname).indexOf('/truyen/') !== 0) { return; }
            function send(tag, payload) {
                try {
                    window.webkit.messageHandlers.chapter.postMessage({tag: tag, payload: String(payload)});
                } catch(e) {}
                try { console.log('[chapter:' + tag + '] ' + String(payload)); } catch(e) {}
            }
            send('onpage', window.location.href);
            // 正文容器优先；外层容器(#content-container)会包含占位/脚本，放后面作兜底
            var CANDIDATES = [
                '#maincontent', '.contentbox', '#chapter-content', '.chapter-content',
                '.chaptertext', '#vcontent', '.chapter_body', '.chapter__content',
                '#chcontent', '#chapterbody', '#content', '#reader',
                '#content-container', '.content'
            ];
            var PLACEHOLDER = /Nh\\u1ea5p v\\u00e0o|\\u0110ang t\\u1ea3i|spinner-border|\\u0110ang t\\u1ea3i n\\u1ed9i dung|vui l\\u00f2ng|click.*t\\u1ea3i/i;
            function textLen(el) {
                try { return el.innerText.replace(/\\s+/g, ' ').trim().length; } catch(e) { return 0; }
            }
            // 就绪判定：排除占位符，要求含正文段落 <p> 或有效文字足够长
            function isReady(el) {
                try {
                    var h = el.innerHTML || '';
                    if (PLACEHOLDER.test(h)) return false;
                    var pCount = (h.match(/<p[ >]/g) || []).length;
                    if (pCount >= 1) return true;
                    if (textLen(el) > 300) return true;
                    return false;
                } catch(e) { return false; }
            }
            // 提取真正正文 HTML：若选中容器内含正文段落节点，取其段落；否则用容器自身
            function extractHTML(el) {
                try {
                    var p = el.querySelector('p');
                    if (p && p.parentElement === el) { return el.innerHTML; }
                    return el.innerHTML;
                } catch(e) { return el.innerHTML; }
            }
            var selState = {};
            var t = setInterval(function() {
                try {
                    var report = [];
                    var foundEl = null, foundSel = null;
                    for (var i = 0; i < CANDIDATES.length; i++) {
                        var sel = CANDIDATES[i];
                        var el;
                        try { el = document.querySelector(sel); } catch(e) { el = null; }
                        if (!el) { if (selState[sel] !== 'absent') { selState[sel] = 'absent'; report.push(sel + '=absent'); } continue; }
                        var ready = isReady(el);
                        if (!selState[sel] || selState[sel].indexOf('ready') < 0) {
                            selState[sel] = 'present len=' + textLen(el) + ' p=' + ((el.innerHTML.match(/<p[ >]/g) || []).length) + ' ready=' + ready;
                        }
                        report.push(sel + '=' + selState[sel]);
                        if (!foundEl && ready) { foundEl = el; foundSel = sel; }
                    }
                    if (!foundEl) {
                        send('probe', report.join(' | ') + ' | href=' + location.href);
                        return;
                    }
                    clearInterval(t);
                    var html = extractHTML(foundEl);
                    // 标题
                    var title = '';
                    var tEl = document.querySelector('.chaptername') || document.querySelector('h1') || document.querySelector('#chaptername') || document.querySelector('.chapter-title');
                    if (tEl) { try { title = tEl.textContent.trim(); } catch(e) {} }
                    // 从 URL 解析 h / bookid / c  (pathname=/truyen/{h}/{type}/{bookid}/{c}/)
                    var h = '', bookid = '', c = '';
                    try {
                        var m = location.pathname.match(/\\/truyen\\/([^\\/]+)\\/\\d+\\/([^\\/]+)\\/([^\\/]+)\\/?/);
                        if (m) { h = m[1]; bookid = m[2]; c = m[3]; }
                    } catch(e) {}
                    send('content', JSON.stringify({
                        html: html, title: title,
                        h: h, bookid: bookid, c: c, sel: foundSel, href: location.href
                    }));
                } catch(e) { send('extract-err', String(e)); }
            }, 500);
            // 验证/加载可能较久，延长等待
            setTimeout(function() { clearInterval(t); }, 180000);
        })();
        """
        let chapterExtractScript = WKUserScript(source: chapterExtractJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        controller.addUserScript(chapterExtractScript)

        // ===== 临时调试插桩 (debug-point) =====
        // #region debug-point D:ios-evidence
        let debugScript = WKUserScript(source: debugJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        controller.addUserScript(debugScript)
        controller.add(self, name: "dbg")
        controller.add(self, name: "chapter")
        // #endregion

        config.userContentController = controller
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // 使用标准 iPhone Safari UA，去掉 SangTacVietApp 后缀。
        // 已用 Chrome 覆盖 UA 实测：readchapter 接口按 UA 判定设备，
        // 带 "SangTacVietApp/1.2.17" 的自定义 UA 会被服务器判为不受支持的设备
        // 返回 {"code":7}（Device not supported）；标准 Safari UA 则返回 code:0 正常正文。
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        webView.isOpaque = true
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    // ===== 临时调试插桩注入脚本 (debug-point D) =====
    private let debugJS = """
    (function(){
        function dbg(tag, msg) {
            try {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dbg) {
                    window.webkit.messageHandlers.dbg.postMessage({tag:tag, msg:String(msg)});
                }
            } catch(e) {}
        }
        dbg('init', 'origin=' + window.location.origin + ' href=' + window.location.href + ' winOriginType=' + (typeof window.origin) + ' winOriginVal=' + (window.origin === undefined ? 'UNDEF' : String(window.origin)));
        try { dbg('ua', navigator.userAgent); } catch(e){}
        try { dbg('platform', navigator.platform + ' | maxTouch=' + (navigator.maxTouchPoints!==undefined?navigator.maxTouchPoints:'na') + ' | wd=' + (navigator.webdriver===true)); } catch(e){}
        var _dbgXhrOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url) {
            try { this._dbgUrl = url; } catch(e){}
            try { dbg('xhr-open', method + ' -> ' + url); } catch(e){}
            return _dbgXhrOpen.apply(this, arguments);
        };
        // 捕获 readchapter / chapterlist 请求实际设置的请求头，判断服务器判定依据
        var _dbgSetHeader = XMLHttpRequest.prototype.setRequestHeader;
        XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
            try {
                if (String(this._dbgUrl||'').indexOf('readchapter') > -1 || String(this._dbgUrl||'').indexOf('chapterlist') > -1) {
                    var rec = this._dbgHeaders || (this._dbgHeaders = {});
                    rec[name] = value;
                }
            } catch(e) {}
            return _dbgSetHeader.apply(this, arguments);
        };
        var _dbgXhrSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.send = function(body) {
            var xhr = this;
            try {
                dbg('xhr-send', 'url=' + xhr.responseURL);
                if (String(xhr._dbgUrl||'').indexOf('readchapter') > -1) {
                    dbg('xhr-body-req', 'body=' + String(body === undefined ? '' : body).slice(0, 300));
                }
                var oldOnerror = xhr.onerror;
                xhr.onerror = function(e) {
                    dbg('xhr-error', 'status=' + xhr.status + ' url=' + xhr.responseURL);
                    if (oldOnerror) oldOnerror.apply(this, arguments);
                };
                var oldOnload = xhr.onload;
                xhr.onload = function(e) {
                    try { dbg('xhr-load', 'status=' + xhr.status + ' size=' + (xhr.responseText ? xhr.responseText.length : 0) + ' url=' + xhr.responseURL); } catch(err){ dbg('xhr-load-err', String(err)); }
                    try {
                        if (String(xhr._dbgUrl||'').indexOf('readchapter') > -1) {
                            dbg('xhr-hdrs', 'REQ-HDRS=' + JSON.stringify(xhr._dbgHeaders || {}) + ' | respHdr=' + (xhr.getAllResponseHeaders ? xhr.getAllResponseHeaders() : ''));
                            dbg('xhr-cookie', document.cookie);
                            try { dbg('xhr-body', 'resp=' + String(xhr.responseText).slice(0, 300)); } catch(err){}
                        }
                    } catch(err) {}
                    if (oldOnload) oldOnload.apply(this, arguments);
                };
            } catch(e) { dbg('xhr-send-wrap-err', String(e)); }
            return _dbgXhrSend.apply(this, arguments);
        };
        (function(){
            var t = setInterval(function(){
                try {
                    if (window.app && window.app.net && window.app.net.networkManagerXHR) {
                        dbg('patch', 'nm-exists; isDomainAlivePatched=' + (window.app.net.networkManagerXHR.isDomainAlive.toString().indexOf('curOrigin') > -1));
                        clearInterval(t);
                    }
                } catch(e) {}
            }, 500);
            setTimeout(function(){ clearInterval(t); }, 8000);
        })();
        dbg('ready', 'instrumentation installed');
    })();
    """

    private func loadApp() {
        // 入口域名必须落在前端 app.v2.js 的 networkManagerXHR.defaultDomains 内，
        // 否则 fullUrl() 会把所有请求切换到镜像域名，跨域 XHR 不携带本域 Cookie，
        // 导致登录/语言切换/源目录加载失败。
        // 域名选择：sangtacviet.com 的 Cloudflare 挑战在 WKWebView 里无法自动完成，
        // cf_clearance 永不签发导致 readchapter 无限 code:7。用户实测 sangtacviet.vip
        // 的 Cloudflare 为托管型挑战（managed challenge），能在浏览器里自动完成并签发
        // cf_clearance，从而让正文加载成功。故入口使用 sangtacviet.vip。
        let targetURL = URL(string: "https://sangtacviet.vip/app.v2.php") ?? URL(string: "https://sangtacviet.vip/")!
        var request = URLRequest(url: targetURL)
        request.setValue("https://sangtacviet.vip", forHTTPHeaderField: "Referer")
        webView.load(request)
    }

    // MARK: - WKNavigationDelegate
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 全面放行应用内部请求与导航
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let err = error as NSError
        if err.code == NSURLErrorCancelled { return }
        print("Web load failed: \(error.localizedDescription)")
        
        // 自动重试或者备选域名
        if let currentURL = webView.url?.absoluteString, currentURL.contains("sangtacviet.vip") {
            if let fallbackURL = URL(string: "https://sangtacviet.com/app.v2.php") {
                webView.load(URLRequest(url: fallbackURL))
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 触发一次 resize，让前端重新测量 --vh 等视口变量
        webView.evaluateJavaScript("window.dispatchEvent(new Event('resize'));", completionHandler: nil)
    }

    // ===== 临时调试插桩 handler (debug-point D) =====
    // #region debug-point D:handle
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "dbg", let body = message.body as? [String: Any] {
            let tag = body["tag"] as? String ?? "?"
            let msg = body["msg"] as? String ?? ""
            // 主线程刷新 UI
            DispatchQueue.main.async {
                self.appendDebugLog("[DBG:\(tag)] \(msg)")
            }
        } else if message.name == "chapter", let body = message.body as? [String: Any] {
            let tag = body["tag"] as? String ?? "?"
            let payload = body["payload"] as? String ?? ""
            DispatchQueue.main.async {
                self.handleChapterMessage(tag: tag, payload: payload)
            }
        }
    }
    // #endregion

    // ===== 章节页正文提取 -> 全屏沉浸阅读页 (v13) =====
    private func handleChapterMessage(tag: String, payload: String) {
        appendDebugLog("[chapter:\(tag)] \(String(payload.prefix(300)))")
        if tag == "content" {
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let html = obj["html"] as? String else {
                appendDebugLog("[chapter:content-parse-err] payload=\(payload.prefix(200))")
                return
            }
            let h = obj["h"] as? String ?? ""
            let bookid = obj["bookid"] as? String ?? ""
            let c = obj["c"] as? String ?? ""
            let title = obj["title"] as? String ?? ""
            appendDebugLog("[chapter:content-ok] sel=\(obj["sel"] as? String ?? "?") title=\(title) h=\(h) bookid=\(bookid) c=\(c) htmlLen=\(html.count)")
            // 若用户已翻到其它章节，忽略旧章节的迟到上报，避免阅读页被错误覆盖
            if let expected = readerExpectedC, !c.isEmpty, c != expected {
                appendDebugLog("[reader] ignore stale content c=\(c) expected=\(expected)")
                return
            }
            // 同一章节已显示则跳过，避免章节页 reload 导致的重复刷新
            if readerLoadedC == c && readerContainer != nil && !readerContainer.isHidden {
                appendDebugLog("[reader] already loaded c=\(c), skip")
                return
            }
            readerLastData = (h, bookid, c)
            presentReader(html: html, title: title)
        }
    }

    private func presentReader(html: String, title: String) {
        if readerContainer == nil { buildReaderUI() }
        readerTitleLabel.text = title.isEmpty ? "阅读器" : title
        let page = readerHTML(title: title, body: html)
        readerView.loadHTMLString(page, baseURL: URL(string: "https://sangtacviet.vip"))
        readerContainer.isHidden = false
        view.bringSubviewToFront(readerContainer)
        if let c = readerLastData?.c { readerLoadedC = c; readerExpectedC = c }
        appendDebugLog("[reader] presented, htmlLen=\(html.count)")
        // v14 实验：章节页会话已建立，用原生 URLSession 验证签名必要性
        if let d = readerLastData {
            testNativeReadChapter(h: d.h, bookid: d.bookid, c: d.c)
        }
    }

    private func dismissReader() {
        readerContainer.isHidden = true
        appendDebugLog("[reader] dismissed")
    }

    // ===== 原生网络实验 (v14)：验证 X-STV-Sign 签名是否必需 (com.sangtacviet) =====
    // 安卓 app 用原生网络栈(Capacitor Http/OkHttp)发 readchapter，带 X-STV-Sign 签名头。
    // 本实验用 iOS 原生 URLSession 复刻同样请求，对比有无签名/不同 UA，看服务器是否 code:0，
    // 从而判定：①是否只需原生网络栈+cookie；②签名是否必需；③假签名是否够用。
    private func testNativeReadChapter(h: String, bookid: String, c: String) {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { cookies in
            let cookieStr = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            // 附带章节页会话关键 cookie（若在）
            let base = "https://sangtacviet.vip/index.php?bookid=\(bookid)&h=\(h)&c=\(c)&ngmar=readc&sajax=readchapter&sty=1&exts="
            self.appendDebugLog("[native] cookies=\(cookieStr.prefix(200))")
            self.nativePost(url: base, cookie: cookieStr, sign: nil, ua: self.iosUA, label: "no-sign-iosUA")
            self.nativePost(url: base, cookie: cookieStr, sign: "00000000000000000000000000000000", ua: self.iosUA, label: "fakesign-iosUA")
            self.nativePost(url: base, cookie: cookieStr, sign: "00000000000000000000000000000000", ua: self.androidUA, label: "fakesign-androidUA")
        }
    }

    private var iosUA: String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    }
    private var androidUA: String {
        "Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
    }

    private func nativePost(url: String, cookie: String, sign: String?, ua: String, label: String) {
        guard let u = URL(string: url) else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("XmlHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("https://sangtacviet.vip", forHTTPHeaderField: "Referer")
        if let sign = sign {
            req.setValue(sign, forHTTPHeaderField: "X-STV-Sign")
        }
        let start = Date()
        let task = URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            var out = "[native:\(label)] "
            if let e = err { out += "err=\(e.localizedDescription)"; self?.appendDebugLog(out); return }
            if let r = resp as? HTTPURLResponse {
                out += "status=\(r.statusCode) "
                let hdrs = r.allHeaderFields
                if let sig = hdrs["X-STV-Sign"] ?? hdrs["x-stv-sign"] { out += "respSign=\(sig) " }
            }
            if let d = data, let s = String(data: d, encoding: .utf8) {
                out += "body=\(s.prefix(160))"
            } else { out += "no-body" }
            out += String(format: " (%.1fs)", Date().timeIntervalSince(start))
            self?.appendDebugLog(out)
        }
        task.resume()
    }

    private func buildReaderUI() {
        let container = UIView()
        container.backgroundColor = .black
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        container.isHidden = true

        // 顶栏：关闭 | 标题 | 上一章/下一章
        let topBar = UIView()
        topBar.backgroundColor = UIColor(white: 0.12, alpha: 1)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(topBar)

        let closeBtn = UIButton(type: .system)
        closeBtn.setTitle("✕ 返回", for: .normal)
        closeBtn.setTitleColor(.white, for: .normal)
        closeBtn.addTarget(self, action: #selector(readerCloseTapped), for: .touchUpInside)
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(closeBtn)

        let titleLbl = UILabel()
        titleLbl.textColor = .white
        titleLbl.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLbl.textAlignment = .center
        titleLbl.numberOfLines = 1
        titleLbl.lineBreakMode = .byTruncatingTail
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(titleLbl)
        readerTitleLabel = titleLbl

        let prevBtn = UIButton(type: .system)
        prevBtn.setTitle("←上", for: .normal)
        prevBtn.setTitleColor(.white, for: .normal)
        prevBtn.addTarget(self, action: #selector(readerPrevTapped), for: .touchUpInside)
        prevBtn.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(prevBtn)

        let nextBtn = UIButton(type: .system)
        nextBtn.setTitle("下→", for: .normal)
        nextBtn.setTitleColor(.white, for: .normal)
        nextBtn.addTarget(self, action: #selector(readerNextTapped), for: .touchUpInside)
        nextBtn.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(nextBtn)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: container.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: readerTopBarHeight + view.safeAreaInsets.top),

            closeBtn.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 8),
            closeBtn.centerYAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -(readerTopBarHeight / 2)),
            closeBtn.widthAnchor.constraint(equalToConstant: 70),

            prevBtn.leadingAnchor.constraint(equalTo: closeBtn.trailingAnchor, constant: 4),
            prevBtn.centerYAnchor.constraint(equalTo: closeBtn.centerYAnchor),
            prevBtn.widthAnchor.constraint(equalToConstant: 52),

            nextBtn.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -8),
            nextBtn.centerYAnchor.constraint(equalTo: closeBtn.centerYAnchor),
            nextBtn.widthAnchor.constraint(equalToConstant: 52),

            titleLbl.leadingAnchor.constraint(equalTo: prevBtn.trailingAnchor, constant: 4),
            titleLbl.trailingAnchor.constraint(equalTo: nextBtn.leadingAnchor, constant: -4),
            titleLbl.centerYAnchor.constraint(equalTo: closeBtn.centerYAnchor)
        ])

        // 正文 WKWebView
        let wvConfig = WKWebViewConfiguration()
        wvConfig.websiteDataStore = WKWebsiteDataStore.default()
        let readerWv = WKWebView(frame: .zero, configuration: wvConfig)
        readerWv.backgroundColor = .systemBackground
        readerWv.isOpaque = false
        readerWv.scrollView.contentInsetAdjustmentBehavior = .never
        readerWv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(readerWv)
        NSLayoutConstraint.activate([
            readerWv.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            readerWv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            readerWv.trailingAnchor.constraint(equalTo: container.trailingAnchor)
            // 底部约束在 settingsBar 创建后统一添加，避免与 container.bottom 冲突
        ])
        readerView = readerWv

        // 阅读设置条（底部）：字号-/A /A+ /夜间 /白天
        let settingsBar = UIView()
        settingsBar.backgroundColor = UIColor(white: 0.12, alpha: 1)
        settingsBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(settingsBar)
        let fontDown = UIButton(type: .system)
        fontDown.setTitle("A-", for: .normal)
        fontDown.setTitleColor(.white, for: .normal)
        fontDown.addTarget(self, action: #selector(readerFontDown), for: .touchUpInside)
        fontDown.translatesAutoresizingMaskIntoConstraints = false
        settingsBar.addSubview(fontDown)

        let fontUp = UIButton(type: .system)
        fontUp.setTitle("A+", for: .normal)
        fontUp.setTitleColor(.white, for: .normal)
        fontUp.addTarget(self, action: #selector(readerFontUp), for: .touchUpInside)
        fontUp.translatesAutoresizingMaskIntoConstraints = false
        settingsBar.addSubview(fontUp)

        let nightBtn = UIButton(type: .system)
        nightBtn.setTitle("🌙夜间", for: .normal)
        nightBtn.setTitleColor(.white, for: .normal)
        nightBtn.addTarget(self, action: #selector(readerNightToggle), for: .touchUpInside)
        nightBtn.translatesAutoresizingMaskIntoConstraints = false
        settingsBar.addSubview(nightBtn)

        let dayBtn = UIButton(type: .system)
        dayBtn.setTitle("☀白天", for: .normal)
        dayBtn.setTitleColor(.white, for: .normal)
        dayBtn.addTarget(self, action: #selector(readerDayMode), for: .touchUpInside)
        dayBtn.translatesAutoresizingMaskIntoConstraints = false
        settingsBar.addSubview(dayBtn)

        NSLayoutConstraint.activate([
            settingsBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            settingsBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            settingsBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            settingsBar.heightAnchor.constraint(equalToConstant: 44 + view.safeAreaInsets.bottom),

            fontDown.leadingAnchor.constraint(equalTo: settingsBar.leadingAnchor, constant: 16),
            fontDown.topAnchor.constraint(equalTo: settingsBar.topAnchor, constant: 8),
            fontDown.widthAnchor.constraint(equalToConstant: 56),
            fontDown.heightAnchor.constraint(equalToConstant: 30),

            fontUp.leadingAnchor.constraint(equalTo: fontDown.trailingAnchor, constant: 8),
            fontUp.topAnchor.constraint(equalTo: fontDown.topAnchor),
            fontUp.widthAnchor.constraint(equalToConstant: 56),
            fontUp.heightAnchor.constraint(equalToConstant: 30),

            nightBtn.trailingAnchor.constraint(equalTo: dayBtn.leadingAnchor, constant: -12),
            nightBtn.centerYAnchor.constraint(equalTo: fontDown.centerYAnchor),
            nightBtn.widthAnchor.constraint(equalToConstant: 72),

            dayBtn.trailingAnchor.constraint(equalTo: settingsBar.trailingAnchor, constant: -16),
            dayBtn.centerYAnchor.constraint(equalTo: fontDown.centerYAnchor),
            dayBtn.widthAnchor.constraint(equalToConstant: 72)
        ])

        // 把 readerWv 底部从 container.bottom 改接到 settingsBar.top，避免被设置条遮挡
        readerWv.bottomAnchor.constraint(equalTo: settingsBar.topAnchor).isActive = true

        // 让 readerWv 底部不被设置条遮挡
        readerWvBottomInset()

        readerContainer = container
    }

    private func readerWvBottomInset() {
        // 正文底部留出设置条高度
        readerView.scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 44, right: 0)
    }

    @objc private func readerCloseTapped() {
        dismissReader()
    }

    @objc private func readerPrevTapped() {
        readerGo(delta: -1)
    }

    @objc private func readerNextTapped() {
        readerGo(delta: 1)
    }

    // 上一章/下一章：导航到章节页，等待提取脚本重新上报正文
    private func readerGo(delta: Int) {
        guard let info = readerLastData else {
            appendDebugLog("[reader] no last data for nav")
            return
        }
        var cVal = Int64(info.c) ?? 0
        cVal += Int64(delta)
        let newC = String(cVal)
        // 更新期望章节，忽略旧章节迟到上报；清空已加载标记以便新章节可 present
        readerExpectedC = newC
        readerLoadedC = nil
        let chapUrl = "https://sangtacviet.vip/truyen/\(info.h)/1/\(info.bookid)/\(newC)/"
        appendDebugLog("[reader] nav to \(chapUrl)")
        // 让底层 webView 导航到章节页
        if let url = URL(string: chapUrl) {
            webView.load(URLRequest(url: url))
            // 等章节页提取后 presentReader 会再次调用
        }
    }

    @objc private func readerFontDown() {
        adjustReaderFont(delta: -2)
    }

    @objc private func readerFontUp() {
        adjustReaderFont(delta: 2)
    }

    private func adjustReaderFont(delta: CGFloat) {
        readerView.evaluateJavaScript("readerAdjustFont(\(delta))", completionHandler: nil)
    }

    @objc private func readerNightToggle() {
        readerView.evaluateJavaScript("readerNightMode(true)", completionHandler: nil)
    }

    @objc private func readerDayMode() {
        readerView.evaluateJavaScript("readerNightMode(false)", completionHandler: nil)
    }

    // 自包含阅读页 HTML：正文 + 沉浸式排版 + 字号/夜间模式 JS
    private func readerHTML(title: String, body: String) -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
        <style>
            :root { --bg:#f5f0e6; --fg:#2b2b2b; --title:#7a6a4a; }
            @media (prefers-color-scheme: dark) {
                :root { --bg:#1a1a1a; --fg:#c8c8c8; --title:#9a8a6a; }
            }
            body { background: var(--bg); color: var(--fg); margin:0; padding: 20px 20px 80px; }
            .stv-chapter-title { text-align:center; font-size:22px; font-weight:bold; color:var(--title); margin: 8px 0 20px; line-height:1.4; }
            .stv-body { font-size: 19px; line-height: 1.9; letter-spacing:0.2px; word-break: break-word; }
            .stv-body p { margin: 0.6em 0; text-indent: 2em; }
            .stv-body img { max-width: 100% !important; height: auto !important; }
            .stv-body i[data-stv-ruby] { color: var(--title); }
        </style>
        </head>
        <body>
            <div class="stv-chapter-title">\(htmlEscape(title))</div>
            <div class="stv-body" id="stvBody">\(body)</div>
            <script>
            var stvFont = 19;
            function readerAdjustFont(d) {
                stvFont = Math.max(14, Math.min(32, stvFont + d));
                var b = document.getElementById('stvBody');
                if (b) b.style.fontSize = stvFont + 'px';
            }
            function readerNightMode(night) {
                var r = document.documentElement;
                if (night) {
                    r.style.setProperty('--bg', '#1a1a1a');
                    r.style.setProperty('--fg', '#c8c8c8');
                    r.style.setProperty('--title', '#9a8a6a');
                } else {
                    r.style.setProperty('--bg', '#f5f0e6');
                    r.style.setProperty('--fg', '#2b2b2b');
                    r.style.setProperty('--title', '#7a6a4a');
                }
            }
            </script>
        </body>
        </html>
        """
    }

    private func htmlEscape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        return out
    }

}

/// 监听 WKWebView cookie 变化，回调宿主保存到 UserDefaults，
/// 规避 LiveContainer 下 WKWebsiteDataStore 持久化失效导致的登录态丢失。
private class CookieObserver: NSObject, WKHTTPCookieStoreObserver {
    private weak var owner: WebViewController?
    init(owner: WebViewController) { self.owner = owner }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        owner?.saveCookies()
    }
}
