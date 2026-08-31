import UIKit
import WebKit

class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

    var webView: WKWebView!

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
            // ===== iOS 章节读取修复：不注入 window.Capacitor =====
            // 已通过真实登录会话 + Chrome 抓包确认真相：
            //   1) 成功读取章节的请求格式为（不需要 key、不需要 grantcontext/eval）：
            //        /index.php?bookid={bookid}&h={源名}&c={章节}&ngmar=readc&sajax=readchapter&sty=1&exts=
            //      返回 {"code":"0", ...data}。
            //   2) 前端 app.v2.read.js 的 getContent(615) 构造的
            //        /?sajax=readchapter&h=&bookid=&c=&key=undefined
            //      缺 ngmar/sty/exts 且多带 key=undefined -> 服务器返回 {"code":7}
            //      (Device not supported) -> "Kết nối tới máy chủ thất bại"。
            //   3) grantcontext 返回的 JSFuck 代码在任何环境 eval 均返回 undefined、
            //      无副作用，且 key 参数根本不需要 -> 覆写 loadKeyFromServer 毫无意义。
            //
            // 因此本修复：保持纯 Web 布局（不注入 Capacitor，避免布局塌陷），
            // 只覆写 app.reader.getContent，用上面验证过的成功格式请求章节正文。
            function tryDbg(tag, msg) {
                try {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dbg) {
                        window.webkit.messageHandlers.dbg.postMessage({tag: tag, msg: String(msg)});
                        return;
                    }
                } catch(e) {}
                try { console.log('[key:' + tag + '] ' + msg); } catch(e) {}
            }
            // 用同源 XHR 请求章节正文（复用 app.net 走同源 + x-stv-transport:web 头，
            // 已验证该头可成功返回正文；且现有代码已把网络层强制保持同源）。
            function patchReaderGetContent(app) {
                try {
                    if (!app || !app.reader) return false;
                    if (app.reader.__getContentPatched) return true;
                    app.reader.__getContentPatched = true;
                    var origGetContent = app.reader.getContent;
                    app.reader.getContent = async function(h, i, c, rl) {
                        var self = this;
                        // 保留离线书逻辑
                        if (self.offlineBook && !rl) {
                            try {
                                var cdata = await self.offlineBook.getChapterOrNull(c);
                                if (cdata) return JSON.parse(cdata);
                            } catch(e) {}
                        }
                        try { self.setTransMode(); } catch(e) {}
                        // 记录传入的真实参数，便于确认 h 是源名还是数字
                        tryDbg('gc', 'h=' + h + ' i/bookid=' + i + ' c=' + c + ' rl=' + rl);
                        // 用验证过的成功格式请求（不需要 key）。
                        // 强制用当前页同源 origin 构造绝对 URL，避免 fullUrl 切到镜像域触发跨域拦截。
                        var base = window.location.origin;
                        var url = base + "/index.php?bookid=" + encodeURIComponent(i)
                                + "&h=" + encodeURIComponent(h)
                                + "&c=" + encodeURIComponent(c)
                                + "&ngmar=readc&sajax=readchapter&sty=1&exts=";
                        if (rl) url += "&rescan=true";
                        tryDbg('gc-url', url);
                        // 用原生 XHR 模拟 App 客户端请求，而不是 app.net.get()。
                        // 原因：app.net.get() 内部强制给所有 GET 加 "x-stv-transport: web" 头，
                        // 服务器对 readchapter 见到 web 传输会返回 {"code":7}（设备不兼容或版本过时，
                        // 即"网页版已过时，请改用 App"）。而安卓真实 App 走 Capacitor 用的是
                        // "x-stv-transport: app" + "x-requested-with" 头，服务器据此放行并返回正文。
                        // 这里完全复刻 App 客户端的请求头，让服务器把请求当作 App 客户端处理。
                        try {
                            var cdata = await new Promise(function(resolve, reject) {
                                var xhr = new XMLHttpRequest();
                                xhr.open("GET", url, true);
                                xhr.setRequestHeader("x-stv-transport", "app");
                                xhr.setRequestHeader("x-requested-with", "com.sangtacviet.mobilereader");
                                // 同源 XHR 由 WKWebView 自动携带 Cookie 与 Referer；再显式补一个
                                // Referer 确保非空（服务器对 GET readchapter 强制要求非空 Referer）。
                                xhr.setRequestHeader("Referer", document.referrer || window.location.href);
                                xhr.onreadystatechange = function() {
                                    if (xhr.readyState === 4) {
                                        if (xhr.status === 200) {
                                            try { resolve(JSON.parse(xhr.responseText)); }
                                            catch(e) { resolve(xhr.responseText); }
                                        } else {
                                            reject({code:-1, status:xhr.status, text:xhr.responseText});
                                        }
                                    }
                                };
                                xhr.onerror = function() { reject({code:-1, message:"xhr error", status:xhr.status}); };
                                xhr.send();
                            });
                            if (cdata) {
                                if (cdata.code + "" == "0") {
                                    tryDbg('gc-ok', 'len=' + (cdata.data ? cdata.data.length : 0));
                                } else {
                                    tryDbg('gc-code', 'code=' + cdata.code + ' err=' + (cdata.err || '') + ' info=' + (cdata.info || ''));
                                }
                                return cdata;
                            }
                        } catch(e) {
                            tryDbg('gc-err', 'exception: ' + e);
                        }
                        // 回退到原始逻辑
                        return origGetContent.apply(self, arguments);
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
                                // readchapter 请求规范化：原版 getContent 会带上 key=undefined 且缺
                                // ngmar/sty/exts，服务器对这两种情况均返回 code:7。key 参数经多重验证
                                // 根本不需要。这里统一修正为已验证成功的格式。
                                if (url.indexOf('readchapter') > -1) {
                                    var sp = u.searchParams;
                                    if (sp.get('key') === 'undefined') sp.delete('key');
                                    if (!sp.has('ngmar')) sp.set('ngmar', 'readc');
                                    if (!sp.has('sty')) sp.set('sty', '1');
                                    if (!sp.has('exts')) sp.set('exts', '');
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
        let bridgeScript = WKUserScript(source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        controller.addUserScript(bridgeScript)

        // ===== 临时调试插桩 (debug-point) =====
        // #region debug-point D:ios-evidence
        let debugScript = WKUserScript(source: debugJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        controller.addUserScript(debugScript)
        controller.add(self, name: "dbg")
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
        // 与安卓 APK (capacitor.config.json: server.url) 一致，使用 sangtacviet.com。
        let targetURL = URL(string: "https://sangtacviet.com/app.v2.php") ?? URL(string: "https://sangtacviet.com/")!
        var request = URLRequest(url: targetURL)
        request.setValue("https://sangtacviet.com", forHTTPHeaderField: "Referer")
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
        if let currentURL = webView.url?.absoluteString, currentURL.contains("sangtacviet.com") {
            if let fallbackURL = URL(string: "https://sangtacviet.app/app.v2.php") {
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
        }
    }
    // #endregion
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
