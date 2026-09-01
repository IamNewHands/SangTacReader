import UIKit
import WebKit

class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UIPageViewControllerDataSource, UITableViewDataSource, UITableViewDelegate {

    var webView: WKWebView!


    // ===== 全屏沉浸阅读页 (v13 -> v15 原生渲染) =====
    // 章节页正文提取后，用原生 UITextView/UIPageViewController 渲染正文，
    // 提供真正的原生 APP 阅读体验（非 webview 壳）。
    private var readerContainer: UIView!
    private var readerContentHolder: UIView!      // 滚动模式容器
    private var readerTextView: UITextView!       // 滚动模式文本视图
    private var readerPageVC: UIPageViewController? // 分页模式
    private var readerModeIsPaged = false         // 当前模式：分页(true)/滚动(false)。默认滚动=安卓默认 slide 上下滑动
    private var readerAttributed: NSAttributedString? // 当前正文富文本
    private var readerRawHTML = ""                // 当前正文原始(中文)HTML，字号调整时重建
    private var readerTitleLabel: UILabel!
    private var readerLastData: (h: String, bookid: String, c: String)? = nil
    private var readerExpectedC: String? = nil   // 用户期望的当前章节 ID，过滤章节页迟到/重复上报
    private var readerLoadedC: String? = nil     // 阅读页已显示的章节 ID
    private var readerFontSize: CGFloat = 18     // 当前字号
    private var readerIsNight = false            // 夜间模式
    private var readerPages: [NSAttributedString] = [] // 分页切片
    private var readerPageOffset: Int = 0        // 分页文本当前页起始 glyph 索引
    private var readerChapterIds: [String] = []  // 章节 ID 列表（真实顺序），供上一章/下一章
    private var readerPrevC = ""                 // 上一章 ID（readchapter 提供）
    private var readerNextC = ""                 // 下一章 ID
    private let readerTopBarHeight: CGFloat = 52

    // ===== 安卓阅读器复刻 (v22)：主题 / 排版 / 底栏 =====
    private var readerThemeIndex = 0             // 当前主题索引（ReaderThemes.all）
    private var readerTopBar: UIView!            // 顶栏：返回 + 标题 + ⋮
    private var readerBottomBar: UIView!         // 底栏：进度条 + 章节名 + 功能按钮
    private var readerProgressSlider: UISlider!  // 章节进度条 (0-1000)
    private var readerChapterNameLabel: UILabel! // 章节名
    private var readerSettingsView: UIView!      // 设置面板（主题/字号/行高/对齐/字体）
    private var readerMenusVisible = true        // 顶/底栏显隐
    private var readerChapterTitles: [String] = [] // 章节标题列表（目录抽屉）
    private var readerDrawerView: UIView!        // 目录抽屉（安卓 view-chapterlist）

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
            // Task1：真正注入极简 Capacitor.Plugins.Http，底层走原生 URLSession(capHttp 桥)。
            // 使原版 loadKeyFromServer/getContent2 走原生 App 通道，避开 Cloudflare 对 webview
            // XHR 的拦截（已实测原生 URLSession 拉 grantcontext 返回混淆 JS，通道有效）。
            // 仅注入 Http，不注入 CapacitorSQLite/Preferences，避免触发原生 SQLite 等待。
            if (!window.hasOwnProperty('Capacitor')) { window.Capacitor = { Plugins: {} }; }
            if (!window.Capacitor.Plugins.Http) {
                window.__capHttpSeq = 0;
                window.__capHttpPending = {};
                window.__capHttpResolve = function(id, payload) {
                    var p = window.__capHttpPending[id];
                    if (!p) return;
                    delete window.__capHttpPending[id];
                    if (payload && payload.error) { p.reject(new Error(payload.error)); }
                    else { p.resolve({ data: (payload && payload.body) || '', status: (payload && payload.status) || 200, headers: {} }); }
                };
                window.Capacitor.Plugins.Http = {
                    get: function(opts) {
                        return new Promise(function(resolve, reject) {
                            var id = (window.__capHttpSeq = window.__capHttpSeq + 1);
                            window.__capHttpPending[id] = { resolve: resolve, reject: reject };
                            var url = opts && opts.url ? String(opts.url) : '';
                            var headers = (opts && opts.headers) || {};
                            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.capHttp) {
                                try { window.webkit.messageHandlers.capHttp.postMessage({ id: id, url: url, headers: headers }); }
                                catch(e) { delete window.__capHttpPending[id]; reject(e); }
                            } else {
                                delete window.__capHttpPending[id];
                                reject(new Error('capHttp missing'));
                            }
                        });
                    },
                    request: function(opts) { return this.get(opts); }
                };
                // 空桩插件：避免前端访问 Capacitor.Plugins.App/StatusBar/Preferences 等时
                // 因 undefined 抛异常（前端多为 try/catch 或有插件检测，此处兜底）。
                if (!window.Capacitor.Plugins.App) { window.Capacitor.Plugins.App = { SyncCookie: function(){}, addListener: function(){ return {remove:function(){}}; } }; }
                if (!window.Capacitor.Plugins.StatusBar) { window.Capacitor.Plugins.StatusBar = { hide: function(){}, show: function(){}, setStyle: function(){}, setBackgroundColor: function(){}, setOverlaysWebView: function(){} }; }
                if (!window.Capacitor.Plugins.Preferences) { window.Capacitor.Plugins.Preferences = { get: function(){ return Promise.resolve({value:null}); }, set: function(){ return Promise.resolve(); }, remove: function(){ return Promise.resolve(); } }; }
                if (!window.Capacitor.Plugins.Device) { window.Capacitor.Plugins.Device = { getInfo: function(){ return Promise.resolve({platform:'ios'}); } }; }
                // 不注入 CapacitorSQLite —— 前端检测到 CapacitorSQLite 才等待原生 SQLite，
                // 不注入则走 localStorage 分支，避免 app.init() 挂起。
            }
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
                    // Task1：不再覆写 loadKeyFromServer —— 注入的 Capacitor.Plugins.Http 已让
                    // 原版走原生 URLSession 拉 grantcontext + eval 生成 key（避开 webview XHR 被
                    // Cloudflare 拦截，已实测原生通道拉 grantcontext 返回混淆 JS 有效）。
                    // 保留 getContent 覆写（整页导航章节页拿正文，由原生阅读页渲染）。
                    app.reader.getContent = async function(h, i, c, rl) {
                        var self = this;
                        if (self.offlineBook && !rl) {
                            try { var cdata = await self.offlineBook.getChapterOrNull(c); if (cdata) return JSON.parse(cdata); } catch(e) {}
                        }
                        try { self.setTransMode(); } catch(e) {}
                        tryDbg('gc', 'h=' + h + ' i/bookid=' + i + ' c=' + c + ' rl=' + rl);
                        // v22(Task1)：先走 getKey(覆写 loadKeyFromServer) 拿 chapterkey，
                        // 供 Swift 原生 URLSession + key 发 readchapter 验证 code:0（方案B核心）。
                        // 若 grantcontext(XHR) 被 Cloudflare 拦导致拿不到 key，日志会暴露 gkey-err。
                        try {
                            var k = await self.getKey(h, i);
                            tryDbg('gc-key', 'got key=' + String(k));
                            window.__lastChapterKey = String(k || '');
                        } catch(e) { tryDbg('gc-key-err', 'exception: ' + e); }
                        // v21：后台取正文 + 完整原生阅读器。点章时主 webview 加载章节页建立
                        // 会话（被原生阅读器覆盖，用户无感知），章节页 readchapter 被拦截上报
                        // Swift，在完整的原生阅读器界面渲染正文。不跳浏览器。
                        try { window.__stvPendingRead = {h:h, bookid:i, c:c}; } catch(e) {}
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nativeRead) {
                            try { window.webkit.messageHandlers.nativeRead.postMessage({h: String(h), bookid: String(i), c: String(c), key: String(window.__lastChapterKey || '')}); } catch(e) {}
                        }
                        var base = window.location.origin;
                        var chapUrl = base + "/truyen/" + encodeURIComponent(h) + "/1/" + encodeURIComponent(i) + "/" + encodeURIComponent(c) + "/";
                        tryDbg('gc-nav', 'navigating to ' + chapUrl);
                        setTimeout(function() { try { window.location.href = chapUrl; } catch(e) {} }, 60);
                        return {code: "1", info: "加载中…"};
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
        controller.add(self, name: "nativeRead")   // v17 原生直读正文
        controller.add(self, name: "capHttp")       // Task1 原生 Capacitor.Http 桥
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
        // v15 中文化：将 STV 正文 HTML 的 <i> 逐词注释替换为中文(t值)，移除顶部灰色提示与版权提示。
        // 输出纯中文正文 HTML（保留 <p>/<br> 段落结构），供 Swift 原生渲染。
        function toChineseContent(raw) {
            try {
                var d = document.createElement('div');
                d.innerHTML = raw;
                // 移除第一个元素：顶部灰色提示 "@Bạn đang đọc bản lưu trong hệ thống"
                var first = d.firstElementChild;
                if (first) {
                    var ft = first.textContent || '';
                    if (/B\\u1ea1n \\u0111ang \\u0111\\u1ecdc b\\u1ea3n l\\u01b0u|b\\u1ea3n l\\u01b0u tr\\u1ecdng h\\u1ec7 th\\u1ed1ng|@Bạn đang đọc/i.test(ft)) {
                        first.remove();
                    }
                }
                // <i> 逐词注释 -> 中文 t 值
                var is = d.querySelectorAll('i');
                for (var k = is.length - 1; k >= 0; k--) {
                    var el = is[k];
                    var cn = el.getAttribute('t');
                    var txt = (cn && cn.length) ? cn : (el.textContent || '');
                    var sp = document.createElement('span');
                    sp.textContent = txt;
                    el.parentNode.replaceChild(sp, el);
                }
                // 移除版权提示文本节点
                var allNodes = d.querySelectorAll('*');
                for (var j = 0; j < allNodes.length; j++) {
                    var nd = allNodes[j];
                    if (!nd.children || nd.children.length) continue;
                    var t2 = nd.textContent || '';
                    if (/V\\u00ec v\\u1ea5n \\u0111\\u1ec1 n\\u1ed9i dung|kh\\u00f4ng h\\u1ed7 tr\\u1ee3 xem v\\u0103n b\\u1ea3n g\\u1ed1c|由于版权问题/i.test(t2)) {
                        nd.remove();
                    }
                }
                return d.innerHTML;
            } catch(e) { return raw; }
        }
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
                            // Task0：提取 chapterkey 供原生 URLSession 直读验证
                            try {
                                var rcUrl = String(xhr._dbgUrl || xhr.responseURL || '');
                                var km = rcUrl.match(/[?&]key=([^&]+)/);
                                if (km && km[1]) { window.__lastChapterKey = decodeURIComponent(km[1]); }
                            } catch(e) {}
                            dbg('xhr-hdrs', 'REQ-HDRS=' + JSON.stringify(xhr._dbgHeaders || {}) + ' | respHdr=' + (xhr.getAllResponseHeaders ? xhr.getAllResponseHeaders() : ''));
                            dbg('xhr-cookie', document.cookie);
                            try { dbg('xhr-body', 'resp=' + String(xhr.responseText).slice(0, 300)); } catch(err){}
                            // v14.1：readchapter code:0 时正文已在响应里，直接提取 data 上报 Swift
                            try {
                                var rTxt = xhr.responseText || '';
                                var rObj = JSON.parse(rTxt);
                                if (rObj && (rObj.code === "0" || rObj.code == 0) && typeof rObj.data === 'string' && rObj.data.length > 0) {
                                    dbg('readc-code0', 'c=' + (rObj.c || '') + ' dataLen=' + rObj.data.length + ' meta=' + JSON.stringify({h:rObj.h,bookid:rObj.bookid,c:rObj.c,prev:rObj.prev,next:rObj.next,prev_c:rObj.prev_c,next_c:rObj.next_c}));
                                    // v15 中文化：<i> 替换为中文 t 值，清理顶部灰色提示与版权提示，输出纯中文正文 HTML
                                    var cnHtml = toChineseContent(rObj.data);
                                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.chapter) {
                                        window.webkit.messageHandlers.chapter.postMessage({
                                            tag: 'content',
                                            payload: JSON.stringify({
                                                h: rObj.h || '',
                                                bookid: rObj.bookid || '',
                                                c: rObj.c || '',
                                                title: (rObj.chaptername || '').trim(),
                                                html: cnHtml,
                                                raw: rObj.data,
                                                prev: rObj.prev || rObj.prev_c || '',
                                                next: rObj.next || rObj.next_c || ''
                                            })
                                        });
                                    }
                                }
                            } catch(err) {}
                        } else if (String(xhr._dbgUrl||'').indexOf('getchapterlist') > -1) {
                            // 拦截章节列表：data 字符串以 -//- 分章、-/- 分字段（cid=字段1, title=字段2）
                            try {
                                var clTxt = xhr.responseText || '';
                                var clObj = JSON.parse(clTxt);
                                var ids = [];
                                var titles = [];
                                var dataStr = (typeof clObj.data === 'string') ? clObj.data : '';
                                if (dataStr) {
                                    var parts = dataStr.split('-//-');
                                    for (var ci = 0; ci < parts.length; ci++) {
                                        var f = parts[ci].split('-/-');
                                        var cid = f[1];
                                        if (cid) { ids.push(String(cid)); titles.push(f[2] || ''); }
                                    }
                                }
                                if (ids.length === 0) {
                                    // 兜底：递归扫描 JSON 找 cid 类字段
                                    (function collect(o) {
                                        if (!o || typeof o !== 'object') return;
                                        if (Array.isArray(o)) { for (var a=0;a<o.length;a++) collect(o[a]); return; }
                                        for (var key in o) {
                                            if (!o.hasOwnProperty(key)) continue;
                                            var v = o[key];
                                            if ((key === 'cid' || key === 'id' || key === 'chapter_id' || key === 'chapterid') && (typeof v === 'string' || typeof v === 'number')) {
                                                ids.push(String(v));
                                            }
                                            collect(v);
                                        }
                                    })(clObj);
                                }
                                if (ids.length > 0 && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.chapter) {
                                    window.webkit.messageHandlers.chapter.postMessage({ tag: 'chapters', payload: JSON.stringify({ ids: ids, titles: titles }) });
                                }
                            } catch(err) {}
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
        // v21：章节页加载完成后若正文还没显示，主动重发一次正确格式 readchapter。
        // log8/log10：章节页自身早期 readchapter 可能带过期校验值而失败（22字节/一直加载中），
        // 重发可确保 code:0。bridgeJS XHR 拦截自动上报 Swift 渲染。
        if let url = webView.url, url.path.contains("/truyen/"), let d = readerLastData,
           let exp = readerExpectedC, readerLoadedC != exp {
            let h = d.h, bi = d.bookid, c = d.c
            let js = """
            (function(){
                try {
                    var h='\(h)', i='\(bi)', c='\(c)';
                    var u='/index.php?bookid='+encodeURIComponent(i)+'&h='+encodeURIComponent(h)+'&c='+encodeURIComponent(c)+'&ngmar=readc&sajax=readchapter&sty=1&exts=';
                    var x=new XMLHttpRequest();
                    x._dbgUrl=u;
                    x.open('POST', u);
                    x.setRequestHeader('Content-Type','application/x-www-form-urlencoded');
                    x.onload=function(){
                        try{
                            var o=JSON.parse(x.responseText);
                            var dbgM='req-readc code='+(o&&o.code)+' len='+(x.responseText||'').length;
                            if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.dbg){
                                window.webkit.messageHandlers.dbg.postMessage({tag:'req-readc',msg:dbgM});
                            }
                        }catch(e){}
                    };
                    x.send('');
                }catch(e){}
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
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
        } else if message.name == "nativeRead", let body = message.body as? [String: Any] {
            // v17：点章 -> JS 直接传 h/bookid/c(+key)，原生 URLSession 直读正文
            let h = body["h"] as? String ?? ""
            let bookid = body["bookid"] as? String ?? ""
            let c = body["c"] as? String ?? ""
            let key = body["key"] as? String ?? ""
            DispatchQueue.main.async {
                self.nativeReadChapter(h: h, bookid: bookid, c: c, key: key)
            }
        } else if message.name == "capHttp", let body = message.body as? [String: Any] {
            // Task1：Capacitor.Plugins.Http 原生桥 —— JS 原生通道请求（grantcontext/readchapter）
            let id = body["id"] as? Int ?? 0
            let url = body["url"] as? String ?? ""
            let headers = body["headers"] as? [String: Any] ?? [:]
            self.capHttpRequest(id: id, url: url, headers: headers)
        }
    }
    // #endregion

    // ===== 章节页正文提取 -> 全屏沉浸阅读页 (v13) =====
    private func handleChapterMessage(tag: String, payload: String) {
        appendDebugLog("[chapter:\(tag)] \(String(payload.prefix(300)))")
        if tag == "chapters" {
            // 保存真实章节 ID 列表（按阅读顺序）
            if let data = payload.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ids = obj["ids"] as? [String] {
                readerChapterIds = ids
                readerChapterTitles = obj["titles"] as? [String] ?? []
                appendDebugLog("[reader] chapter ids stored: \(ids.count) titles: \(readerChapterTitles.count)")
            }
            return
        }
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
            readerPrevC = obj["prev"] as? String ?? ""
            readerNextC = obj["next"] as? String ?? ""
            appendDebugLog("[chapter:content-ok] sel=\(obj["sel"] as? String ?? "?") title=\(title) h=\(h) bookid=\(bookid) c=\(c) htmlLen=\(html.count) prev=\(readerPrevC) next=\(readerNextC)")
            // 若用户已翻到其它章节，忽略旧章节的迟到上报。仅当 expected 非空且不同才过滤，
            // 避免空 expected 误杀首章真实正文。
            if let expected = readerExpectedC, !expected.isEmpty, !c.isEmpty, c != expected {
                appendDebugLog("[reader] ignore stale content c=\(c) expected=\(expected)")
                return
            }
            // 同一章节已显示则跳过，避免章节页 reload 导致的重复刷新
            if readerLoadedC == c && readerContainer != nil && !readerContainer.isHidden {
                appendDebugLog("[reader] already loaded c=\(c), skip")
                return
            }
            // 若上报缺少 h/c（如 DOM 未就绪的探针上报），且已有正确的 readerLastData，则保留旧值
            if (h.isEmpty || c.isEmpty), let last = readerLastData, !last.h.isEmpty, !last.c.isEmpty {
                appendDebugLog("[chapter:content] incomplete h/c, keep last data")
                readerPrevC = obj["prev"] as? String ?? ""
                readerNextC = obj["next"] as? String ?? ""
                if !html.isEmpty { presentReader(html: html, title: title) }
                return
            }
            readerLastData = (h, bookid, c)
            // v21：在完整原生阅读器渲染正文。
            presentReader(html: html, title: title)
        }
    }

    private func presentReader(html: String, title: String) {
        if readerContainer == nil {
            ReaderFontLoader.registerAll()   // 首次进入阅读器注册安卓正文字体
            buildReaderUI()
        }
        readerTitleLabel.text = title.isEmpty ? "阅读器" : title
        readerChapterNameLabel?.text = title.isEmpty ? "" : title
        // v15：HTML 正文 -> 原生富文本 -> 分页/滚动原生渲染
        readerRawHTML = html
        readerContainer.isHidden = false
        view.bringSubviewToFront(readerContainer)
        view.layoutIfNeeded()   // 确保容器有正确尺寸后再分页
        let attr = htmlToAttributed(html)
        readerAttributed = attr
        renderReaderContent(attr)
        // 占位(空正文)不更新已读标记；仅当 c 非空才记录已加载章节。
        // 注意：不在此覆盖 readerExpectedC，避免把用户翻章目标(expected=目标章)
        // 误改回当前已渲染章，导致目标章正文被 stale 过滤丢弃。
        if !html.isEmpty, let c = readerLastData?.c, !c.isEmpty {
            readerLoadedC = c
            if readerExpectedC == nil { readerExpectedC = c }
        }
        appendDebugLog("[reader] presented(\(readerModeIsPaged ? "paged" : "scroll")) attrLen=\(attr.length) charLen=\(attr.string.count)")
    }

    // ===== v15 原生阅读器：HTML -> 富文本 / 分页 / 渲染 =====
    private func htmlToAttributed(_ html: String) -> NSAttributedString {
        // 安卓排版：字号、行高1.8、两端对齐、首行缩进、段间距
        let lh = ReaderDefaultStyle.lineHeight
        let styled = "<span style=\"font-size:\(Int(readerFontSize))pt;line-height:\(lh);text-align:justify;text-indent:\(Int(ReaderDefaultStyle.textIndent))px;\">\(html)</span>"
        guard let data = styled.data(using: .utf8),
              let attr = try? NSAttributedString(data: data,
                                                 options: [.documentType: NSAttributedString.DocumentType.html,
                                                           .characterEncoding: String.Encoding.utf8.rawValue],
                                                 documentAttributes: nil) else {
            return NSAttributedString(string: html, attributes: baseTextAttrs())
        }
        let mutable = NSMutableAttributedString(attributedString: attr)
        // 全文统一字体（含富文本可能带来的系统字体差异）
        mutable.addAttribute(.font, value: ReaderFontLoader.font(family: ReaderDefaultStyle.fontFamily, size: readerFontSize), range: NSRange(location: 0, length: mutable.length))
        mutable.addAttribute(.foregroundColor, value: currentReaderTheme().textColor, range: NSRange(location: 0, length: mutable.length))
        // 段间距：基于段落文本应用 paragraph spacing
        mutable.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: mutable.length)) { value, range, _ in
            let ps = ((value as? NSParagraphStyle) ?? NSParagraphStyle.default).mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            ps.alignment = .justified
            ps.lineSpacing = (lh - 1.0) * readerFontSize
            ps.paragraphSpacing = ReaderDefaultStyle.paragraphSpacing
            ps.firstLineHeadIndent = ReaderDefaultStyle.textIndent
            mutable.addAttribute(.paragraphStyle, value: ps, range: range)
        }
        return mutable
    }

    private func baseTextAttrs() -> [NSAttributedString.Key: Any] {
        let theme = currentReaderTheme()
        return [
            .font: ReaderFontLoader.font(family: ReaderDefaultStyle.fontFamily, size: readerFontSize),
            .foregroundColor: theme.textColor,
            .paragraphStyle: {
                let ps = NSMutableParagraphStyle()
                ps.alignment = .justified
                ps.lineSpacing = (ReaderDefaultStyle.lineHeight - 1.0) * readerFontSize
                ps.paragraphSpacing = ReaderDefaultStyle.paragraphSpacing
                ps.firstLineHeadIndent = ReaderDefaultStyle.textIndent
                return ps
            }()
        ]
    }

    // 把富文本渲染进当前模式（分页/滚动），并应用主题
    private func renderReaderContent(_ attr: NSAttributedString) {
        let theme = currentReaderTheme()
        readerContainer.backgroundColor = theme.backgroundColor
        if readerModeIsPaged {
            buildPagedContent(attr)
        } else {
            buildScrollContent(attr)
        }
    }

    private func currentReaderTheme() -> ReaderTheme {
        let i = min(max(readerThemeIndex, 0), ReaderThemes.all.count - 1)
        return ReaderThemes.all[i]
    }

    // 滚动模式：原生 UITextView
    private func buildScrollContent(_ attr: NSAttributedString) {
        readerPageVC?.view.removeFromSuperview()
        readerPageVC = nil
        readerContentHolder.isHidden = false
        guard let tv = readerTextView else { return }
        let theme = currentReaderTheme()
        tv.attributedText = attr
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = true
        tv.backgroundColor = theme.backgroundColor
        tv.textColor = theme.textColor
        tv.font = ReaderFontLoader.font(family: ReaderDefaultStyle.fontFamily, size: readerFontSize)
        tv.textContainerInset = UIEdgeInsets(top: ReaderDefaultStyle.padding, left: ReaderDefaultStyle.padding, bottom: 44, right: ReaderDefaultStyle.padding)
    }

    // 分页模式：UIPageViewController，每页一个 UITextView 显示一个分页切片
    private func buildPagedContent(_ attr: NSAttributedString) {
        readerContentHolder.isHidden = true
        let vc = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal, options: nil)
        vc.dataSource = self
        vc.view.backgroundColor = currentReaderTheme().backgroundColor
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        if let old = readerPageVC {
            old.view.removeFromSuperview()
        }
        readerContainer.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: readerContainer.topAnchor, constant: readerTopBarHeight + view.safeAreaInsets.top),
            vc.view.leadingAnchor.constraint(equalTo: readerContainer.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: readerContainer.trailingAnchor),
            vc.view.bottomAnchor.constraint(equalTo: readerContainer.bottomAnchor, constant: -(96 + view.safeAreaInsets.bottom))
        ])
        readerPageVC = vc
        view.layoutIfNeeded()   // 确保 readerContainer 有正确尺寸后再分页
        paginateText(attr)
        if let first = makePageVC(index: 0) {
            vc.setViewControllers([first], direction: .forward, animated: false, completion: nil)
        }
    }

    // 用 NSLayoutManager 按行 fragment 累积高度分页（可靠）
    private func paginateText(_ attr: NSAttributedString) {
        readerPages.removeAll()
        readerPageOffset = 0
        let pageWidth = max(readerContainer.bounds.width - 32, 50)
        let pageHeight = max(readerContainer.bounds.height - readerTopBarHeight - 96 - view.safeAreaInsets.top - view.safeAreaInsets.bottom, 100)

        let storage = NSTextStorage(attributedString: attr)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        // 用超高容器排全文，再按行高累积切页
        let container = NSTextContainer(size: CGSize(width: pageWidth, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)

        let full = layout.glyphRange(for: container)
        guard full.length > 0 else {
            readerPages.append(attr)
            appendDebugLog("[reader] paged into 0 pages (empty)")
            return
        }
        // 收集每行 fragment（range + 行高）
        var lines: [(range: NSRange, height: CGFloat)] = []
        var gi = full.location
        while gi < NSMaxRange(full) {
            var eff = NSRange(location: NSNotFound, length: 0)
            let frag = layout.lineFragmentRect(forGlyphAt: gi, effectiveRange: &eff)
            lines.append((eff, frag.height))
            gi = NSMaxRange(eff)
        }
        // 按页高累积切页
        var pageStart = 0
        var acc: CGFloat = 0
        for (li, line) in lines.enumerated() {
            acc += line.height
            if acc > pageHeight && li > pageStart {
                let fromG = lines[pageStart].range.location
                let toG = lines[li].range.location
                if toG > fromG {
                    readerPages.append(attr.attributedSubstring(from: NSRange(location: fromG, length: toG - fromG)))
                }
                pageStart = li
                acc = line.height
            }
        }
        if pageStart < lines.count {
            let fromG = lines[pageStart].range.location
            let toG = NSMaxRange(lines[lines.count - 1].range)
            if toG > fromG {
                readerPages.append(attr.attributedSubstring(from: NSRange(location: fromG, length: toG - fromG)))
            }
        }
        if readerPages.isEmpty { readerPages.append(attr) }
        appendDebugLog("[reader] paged into \(readerPages.count) pages")
    }

    private func makePageVC(index: Int) -> ReaderPageViewController? {
        guard index >= 0 && index < readerPages.count else { return nil }
        let pvc = ReaderPageViewController()
        pvc.pageIndex = index
        let theme = currentReaderTheme()
        pvc.attributedText = readerPages[index]
        pvc.pageBackground = theme.backgroundColor
        pvc.fontSize = readerFontSize
        pvc.textColor = theme.textColor
        return pvc
    }

    private func dismissReader() {
        readerContainer.isHidden = true
        // 若主 webview 已整页导航到章节页，返回时应回到书籍目录页（安卓行为），
        // 而非停留在网页版章节正文页。
        if let url = webView.url, url.path.contains("/truyen/") {
            if webView.canGoBack {
                webView.goBack()
                appendDebugLog("[reader] dismissed, goBack to catalog")
            } else {
                appendDebugLog("[reader] dismissed (no back history)")
            }
        } else {
            appendDebugLog("[reader] dismissed (webview not on chapter)")
        }
    }

    // ===== v20 兜底：直接导航章节页（用 app 自带网页阅读器）=====
    // ===== v21 原生阅读器：主 webview 后台取正文 + 原生覆盖渲染 =====
    // 点章 -> getContent 发 nativeRead -> 这里先显示原生"加载中"占位（覆盖即将导航的章节页，
    // 用户无感知），章节页 readchapter 被拦截 -> 上报 -> 在完整原生阅读器渲染正文。
    private func nativeReadChapter(h: String, bookid: String, c: String, key: String = "") {
        appendDebugLog("[nativeRead] show placeholder h=\(h) bookid=\(bookid) c=\(c) keyLen=\(key.count)")
        guard !h.isEmpty, !bookid.isEmpty, !c.isEmpty else {
            appendDebugLog("[nativeRead] missing params, abort")
            return
        }
        // Task0：用原生 URLSession 带 app 头直读 readchapter，验证能否拿到 code:0（方案B基石）
        probeNativeRead(h: h, bookid: bookid, c: c, key: key)
        // 预置期望章节，使正文上报能通过 handleChapterMessage 过滤
        readerExpectedC = c
        readerLoadedC = nil
        readerLastData = (h, bookid, c)
        // 立即显示原生全屏"加载中"占位（覆盖即将导航的章节页）
        presentReader(html: "<p>加载中…</p>", title: "")
        appendDebugLog("[nativeRead] placeholder shown")
    }

    // Task1：Capacitor.Plugins.Http 原生桥实现 —— JS 原生通道请求（grantcontext/readchapter）。
    // 用原生 URLSession 发请求（复刻安卓 Capacitor.Http），避开 webview XHR 被 Cloudflare 拦。
    private func capHttpRequest(id: Int, url: String, headers: [String: Any]) {
        guard let u = URL(string: url) else {
            capHttpRespond(id: id, status: 0, body: "", error: "bad url")
            return
        }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { [weak self] cookies in
            var cookieStr = ""
            for ck in cookies {
                let d = ck.domain
                if d.contains("sangtacviet") {
                    cookieStr += "\(ck.name)=\(ck.value); "
                }
            }
            // 合并 JS 传入的 Cookie 头（含 mac_tt=true）
            var jsCookie = ""
            if let hc = headers["Cookie"] as? String { jsCookie = hc }
            let mergedCookie = jsCookie.isEmpty ? cookieStr : jsCookie
            if !mergedCookie.contains("mac_tt") { cookieStr = mergedCookie + "mac_tt=true; " }
            else { cookieStr = mergedCookie + " " }

            var req = URLRequest(url: u)
            req.setValue("app", forHTTPHeaderField: "x-stv-transport")
            req.setValue("com.sangtacviet.mobilereader", forHTTPHeaderField: "x-requested-with")
            req.setValue(cookieStr, forHTTPHeaderField: "Cookie")
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
            req.setValue("no-cors", forHTTPHeaderField: "Sec-Fetch-Mode")
            let task = URLSession.shared.dataTask(with: req) { data, resp, err in
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if let err = err {
                    self?.capHttpRespond(id: id, status: status, body: body, error: err.localizedDescription)
                } else {
                    self?.capHttpRespond(id: id, status: status, body: body, error: "")
                }
            }
            task.resume()
        }
    }

    private func capHttpRespond(id: Int, status: Int, body: String, error: String) {
        let payload: String
        if error.isEmpty {
            payload = "{\"status\":\(status),\"body\":" + jsonEscape(body) + ",\"headers\":{}}"
        } else {
            payload = "{\"status\":0,\"body\":\"\",\"headers\":{},\"error\":" + jsonEscape(error) + "}"
        }
        let js = "window.__capHttpResolve && window.__capHttpResolve(\(id), \(payload));"
        DispatchQueue.main.async {
            self.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func jsonEscape(_ s: String) -> String {
        // 简单 JSON 字符串转义（正文含引号/换行/控制字符）
        var o = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            case "\t": o += "\\t"
            default:
                if ch.value < 0x20 { o += String(format: "\\u%04x", ch.value) }
                else { o.unicodeScalars.append(ch) }
            }
        }
        return "\"" + o + "\""
    }

    // Task0 临时验证：原生 URLSession 拉 /io/grantcontext/context，判断原生通道是否被
    // Cloudflare 拦截。返回混淆 JS => 原生通道有效（方案B基石）；返回 CF HTML => 受阻。
    private func probeNativeGrant(h: String, bookid: String) {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { [weak self] cookies in
            var cookieStr = ""
            for ck in cookies {
                let d = ck.domain
                if d.contains("sangtacviet") {
                    cookieStr += "\(ck.name)=\(ck.value); "
                }
            }
            let urlStr = "https://sangtacviet.vip/io/grantcontext/context?hostid=\(h)&bookid=\(bookid)"
            guard let url = URL(string: urlStr) else {
                self?.appendDebugLog("[probe-grant] bad url"); return
            }
            var req = URLRequest(url: url)
            req.setValue("app", forHTTPHeaderField: "x-stv-transport")
            req.setValue("com.sangtacviet.mobilereader", forHTTPHeaderField: "x-requested-with")
            req.setValue(cookieStr + "mac_tt=true;", forHTTPHeaderField: "Cookie")
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
            let task = URLSession.shared.dataTask(with: req) { data, resp, err in
                guard let data = data, let s = String(data: data, encoding: .utf8) else {
                    self?.appendDebugLog("[probe-grant] err=\(String(describing: err))"); return
                }
                if s.contains("cloudflare") || s.lowercased().contains("cf-browser") || s.contains("Just a moment") || s.contains("challenge") {
                    self?.appendDebugLog("[probe-grant] BLOCKED by Cloudflare, bodyLen=\(s.count)")
                } else {
                    self?.appendDebugLog("[probe-grant] OK bodyLen=\(s.count) head=\(s.prefix(80))")
                }
            }
            task.resume()
        }
    }

    // Task0 临时验证：iOS 原生 URLSession 带 app 头 + 会话 cookie 直发 readchapter，
    // 检查返回 code 是否 0（复刻安卓 Capacitor Http 的关键假设）。
    private func probeNativeRead(h: String, bookid: String, c: String, key: String) {
        // 无论 key 是否为空，都先用原生 URLSession 拉 grantcontext，判断原生通道是否被
        // Cloudflare 拦截（若返回混淆 JS 说明原生通道有效，方案B可行；若返回 CF HTML 则受阻）。
        probeNativeGrant(h: h, bookid: bookid)
        if key.isEmpty {
            appendDebugLog("[probe] readchapter SKIP: key empty (getKey 未拿到 key)，仅验证了 grantcontext 原生通道")
            return
        }
        appendDebugLog("[probe] start h=\(h) bookid=\(bookid) c=\(c) key=\(key)")
        // 收集 webview 会话 cookie
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { [weak self] cookies in
            var cookieStr = ""
            for ck in cookies {
                let d = ck.domain
                if d.contains("sangtacviet") {
                    cookieStr += "\(ck.name)=\(ck.value); "
                }
            }
            let urlStr = "https://sangtacviet.vip/?sajax=readchapter&h=\(h)&bookid=\(bookid)&c=\(c)&key=\(key)"
            guard let url = URL(string: urlStr) else {
                self?.appendDebugLog("[probe] bad url"); return
            }
            var req = URLRequest(url: url)
            req.setValue("app", forHTTPHeaderField: "x-stv-transport")
            req.setValue("com.sangtacviet.mobilereader", forHTTPHeaderField: "x-requested-with")
            req.setValue(cookieStr + "mac_tt=true;", forHTTPHeaderField: "Cookie")
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
            let task = URLSession.shared.dataTask(with: req) { data, resp, err in
                guard let data = data, let s = String(data: data, encoding: .utf8) else {
                    self?.appendDebugLog("[probe] err=\(String(describing: err))"); return
                }
                var j = s
                if j.hasPrefix("\u{FEFF}") { j.removeFirst() }
                if j.first != "{" { if let idx = j.firstIndex(of: "{") { j = String(j[idx...]) } }
                if let d = j.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    let code = o["code"] as? String ?? "?"
                    let dataLen = (o["data"] as? String)?.count ?? -1
                    let time = o["time"] as? String ?? "?"
                    self?.appendDebugLog("[probe] RESULT code=\(code) dataLen=\(dataLen) time=\(time) c=\(o["c"] ?? "?")")
                } else {
                    self?.appendDebugLog("[probe] non-json resp=\(s.prefix(200))")
                }
            }
            task.resume()
        }
    }

    // v17：Swift 版中文化（搬移 JS toChineseContent）——移除顶部灰色提示、<i>注释->中文t值、移除版权提示
    private func toChineseContent(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var html = raw
        func regexReplace(_ pattern: String, _ out: (String, [String]) -> String) {
            guard let rx = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            let ns = html as NSString
            let matches = rx.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
            var parts = ""
            var last = 0
            for m in matches {
                parts += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                var groups: [String] = []
                for gi in 0..<m.numberOfRanges {
                    let gr = m.range(at: gi)
                    groups.append(gr.location == NSNotFound ? "" : ns.substring(with: gr))
                }
                let full = ns.substring(with: m.range)
                parts += out(full, groups)
                last = m.range.location + m.range.length
            }
            parts += ns.substring(from: last)
            html = parts
        }
        // 1) 移除顶部灰色提示 "@Bạn đang đọc bản lưu ..."
        regexReplace(#"<p><span style='color:gray.*?</span></p>"#) { _, _ in "" }
        // 2) <i ...t='中文'>原文</i> -> <span>中文</span>
        regexReplace(#"<i\b[^>]*\bt='([^']*)'[^>]*>(.*?)</i>"#) { _, groups in
            let cn = groups.count > 1 ? groups[1] : ""
            return cn.isEmpty ? "" : "<span>" + cn + "</span>"
        }
        // 3) 移除版权提示（含越南语/中文关键词）
        regexReplace(#"(?:Vì vấn đề nội dung|không hỗ trợ xem văn bản gốc|由于版权问题)[^<\n]*"#) { _, _ in "" }
        return html
    }

    private var iosUA: String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    }

    private func buildReaderUI() {
        let container = UIView()
        container.backgroundColor = currentReaderTheme().backgroundColor
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        container.isHidden = true

        // ===== 顶栏（安卓 page-readchapter.titlebar）：返回 | 标题 | ⋮ =====
        let topBar = UIView()
        topBar.backgroundColor = UIColor.black.withAlphaComponent(0.22)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(topBar)
        readerTopBar = topBar

        let closeBtn = UIButton(type: .system)
        closeBtn.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        closeBtn.tintColor = .white
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

        let menuBtn = UIButton(type: .system)
        menuBtn.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        menuBtn.tintColor = .white
        menuBtn.addTarget(self, action: #selector(readerShowDrawer), for: .touchUpInside)
        menuBtn.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(menuBtn)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: container.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: readerTopBarHeight + view.safeAreaInsets.top),

            closeBtn.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 8),
            closeBtn.centerYAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -(readerTopBarHeight / 2)),
            closeBtn.widthAnchor.constraint(equalToConstant: 44),
            closeBtn.heightAnchor.constraint(equalToConstant: 44),

            menuBtn.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -8),
            menuBtn.centerYAnchor.constraint(equalTo: closeBtn.centerYAnchor),
            menuBtn.widthAnchor.constraint(equalToConstant: 44),
            menuBtn.heightAnchor.constraint(equalToConstant: 44),

            titleLbl.leadingAnchor.constraint(equalTo: closeBtn.trailingAnchor, constant: 4),
            titleLbl.trailingAnchor.constraint(equalTo: menuBtn.leadingAnchor, constant: -4),
            titleLbl.centerYAnchor.constraint(equalTo: closeBtn.centerYAnchor)
        ])

        // ===== 正文容器（滚动模式 UITextView；分页模式 UIPageViewController）=====
        let holder = UIView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.backgroundColor = currentReaderTheme().backgroundColor
        container.addSubview(holder)
        NSLayoutConstraint.activate([
            holder.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            holder.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            holder.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        readerContentHolder = holder

        let tv = UITextView()
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = true
        tv.showsVerticalScrollIndicator = false
        tv.font = ReaderFontLoader.font(family: ReaderDefaultStyle.fontFamily, size: readerFontSize)
        tv.backgroundColor = currentReaderTheme().backgroundColor
        tv.textColor = currentReaderTheme().textColor
        tv.textContainerInset = UIEdgeInsets(top: ReaderDefaultStyle.padding, left: ReaderDefaultStyle.padding, bottom: 44, right: ReaderDefaultStyle.padding)
        holder.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: holder.topAnchor),
            tv.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            tv.bottomAnchor.constraint(equalTo: holder.bottomAnchor)
        ])
        readerTextView = tv

        // 点击正文中部切换菜单显隐（安卓 menuTapMode centerlr）
        let tap = UITapGestureRecognizer(target: self, action: #selector(readerToggleMenus))
        holder.addGestureRecognizer(tap)

        // ===== 底栏（安卓 page-readchapter.bottombar）：进度条 + 章节名 + 功能按钮 =====
        buildReaderBottomBar(in: container)

        // holder 底部接到底栏 top
        holder.bottomAnchor.constraint(equalTo: readerBottomBar.topAnchor).isActive = true

        readerContainer = container
    }

    // 底栏：进度条 + 章节名 + 上章/下章/评论/朗读/设置 五按钮
    private func buildReaderBottomBar(in container: UIView) {
        let bar = UIView()
        bar.backgroundColor = UIColor.black.withAlphaComponent(0.22)
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 96 + view.safeAreaInsets.bottom)
        ])
        readerBottomBar = bar

        // 进度条（安卓 chapterprogress，0-1000）
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 1000
        slider.value = 0
        slider.tintColor = .systemBlue
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.addTarget(self, action: #selector(readerProgressChanged(_:)), for: .valueChanged)
        bar.addSubview(slider)
        readerProgressSlider = slider

        // 章节名
        let nameLbl = UILabel()
        nameLbl.textColor = .white
        nameLbl.font = .systemFont(ofSize: 13)
        nameLbl.numberOfLines = 1
        nameLbl.lineBreakMode = .byTruncatingTail
        nameLbl.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(nameLbl)
        readerChapterNameLabel = nameLbl

        // 功能按钮行：上章 | 下章 | 评论 | 朗读 | 设置
        let buttons: [(String, Selector)] = [
            ("chevron.left", #selector(readerPrevTapped)),
            ("chevron.right", #selector(readerNextTapped)),
            ("bubble.left", #selector(readerCommentTapped)),
            ("speaker.wave.2", #selector(readerSpeakTapped)),
            ("gearshape", #selector(readerMenuTapped)),
        ]
        var prevBtn: UIButton?
        for (icon, sel) in buttons {
            let b = UIButton(type: .system)
            b.setImage(UIImage(systemName: icon), for: .normal)
            b.tintColor = .white
            b.addTarget(self, action: sel, for: .touchUpInside)
            b.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(b)
            NSLayoutConstraint.activate([
                b.topAnchor.constraint(equalTo: nameLbl.bottomAnchor, constant: 6),
                b.widthAnchor.constraint(equalToConstant: 52),
                b.heightAnchor.constraint(equalToConstant: 40)
            ])
            if let prev = prevBtn {
                b.leadingAnchor.constraint(equalTo: prev.trailingAnchor).isActive = true
            } else {
                b.leadingAnchor.constraint(equalTo: bar.leadingAnchor).isActive = true
            }
            prevBtn = b
        }

        NSLayoutConstraint.activate([
            slider.topAnchor.constraint(equalTo: bar.topAnchor, constant: 6),
            slider.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            slider.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),

            nameLbl.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 4),
            nameLbl.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            nameLbl.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
        ])
    }

    // 设置面板（安卓 view-stylesetting）：全屏半透明遮罩 + 底部面板（12 主题色块 + 字号）
    private func buildReaderSettingsView() {
        // 全屏遮罩：点击关闭面板
        let mask = UIView()
        mask.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        mask.translatesAutoresizingMaskIntoConstraints = false
        mask.isHidden = true
        let maskTap = UITapGestureRecognizer(target: self, action: #selector(readerSettingsMaskTapped))
        mask.addGestureRecognizer(maskTap)
        view.addSubview(mask)

        let panel = UIView()
        panel.backgroundColor = UIColor(white: 0.12, alpha: 1)
        panel.layer.cornerRadius = 12
        panel.translatesAutoresizingMaskIntoConstraints = false
        mask.addSubview(panel)
        NSLayoutConstraint.activate([
            mask.topAnchor.constraint(equalTo: view.topAnchor),
            mask.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mask.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mask.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panel.heightAnchor.constraint(equalToConstant: 300 + view.safeAreaInsets.bottom)
        ])
        // 用 panel 作为设置容器引用（关闭时隐藏整个 mask）
        readerSettingsView = mask

        let title = UILabel()
        title.text = "样式设置"
        title.textColor = .white
        title.font = .boldSystemFont(ofSize: 15)
        title.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(title)

        // 12 主题色块横向可滚
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(scroll)

        var prevSwatch: UIView?
        for (i, t) in ReaderThemes.all.enumerated() {
            let sw = UIView()
            sw.backgroundColor = t.backgroundColor
            sw.layer.borderWidth = (i == readerThemeIndex) ? 3 : 1
            sw.layer.borderColor = (i == readerThemeIndex) ? UIColor.systemBlue.cgColor : UIColor.white.cgColor
            sw.layer.cornerRadius = 6
            sw.tag = i
            sw.translatesAutoresizingMaskIntoConstraints = false
            let tap = UITapGestureRecognizer(target: self, action: #selector(readerThemeTapped(_:)))
            sw.addGestureRecognizer(tap)
            scroll.addSubview(sw)
            NSLayoutConstraint.activate([
                sw.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 4),
                sw.widthAnchor.constraint(equalToConstant: 44),
                sw.heightAnchor.constraint(equalToConstant: 44)
            ])
            if let p = prevSwatch {
                sw.leadingAnchor.constraint(equalTo: p.trailingAnchor, constant: 10).isActive = true
            } else {
                sw.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 4).isActive = true
            }
            prevSwatch = sw
        }
        if let last = prevSwatch {
            last.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -4).isActive = true
        }

        // 字号行
        let fontRow = UIStackView()
        fontRow.axis = .horizontal
        fontRow.spacing = 12
        fontRow.alignment = .center
        fontRow.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(fontRow)

        let minusBtn = makeSettingsButton(title: "A-", action: #selector(readerFontDown))
        let sizeLbl = UILabel()
        sizeLbl.text = "\(Int(readerFontSize))"
        sizeLbl.textColor = .white
        sizeLbl.font = .systemFont(ofSize: 14)
        sizeLbl.tag = 9001
        sizeLbl.widthAnchor.constraint(equalToConstant: 30).isActive = true
        sizeLbl.textAlignment = .center
        let plusBtn = makeSettingsButton(title: "A+", action: #selector(readerFontUp))
        fontRow.addArrangedSubview(minusBtn)
        fontRow.addArrangedSubview(sizeLbl)
        fontRow.addArrangedSubview(plusBtn)

        // 翻页模式切换：上下滑动 <-> 左右翻页（安卓 slide / pageflip）
        let modeRow = UIStackView()
        modeRow.axis = .horizontal
        modeRow.spacing = 12
        modeRow.alignment = .center
        modeRow.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(modeRow)
        let modeBtn = makeSettingsButton(title: readerModeIsPaged ? "左右翻页" : "上下滑动", action: #selector(readerToggleMode))
        modeBtn.tag = 9002
        modeRow.addArrangedSubview(modeBtn)
        let modeHint = UILabel()
        modeHint.text = "切换翻页方式"
        modeHint.textColor = .white
        modeHint.font = .systemFont(ofSize: 13)
        modeHint.translatesAutoresizingMaskIntoConstraints = false
        modeRow.addArrangedSubview(modeHint)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),

            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            scroll.heightAnchor.constraint(equalToConstant: 56),

            fontRow.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 16),
            fontRow.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),

            modeRow.topAnchor.constraint(equalTo: fontRow.bottomAnchor, constant: 16),
            modeRow.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
        ])
    }

    // 点击遮罩关闭设置面板
    @objc private func readerSettingsMaskTapped() {
        readerSettingsView?.isHidden = true
    }

    private func makeSettingsButton(title: String, action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = .boldSystemFont(ofSize: 15)
        b.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        b.layer.cornerRadius = 6
        b.addTarget(self, action: action, for: .touchUpInside)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 56).isActive = true
        b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return b
    }

    // 点击主题色块
    @objc private func readerThemeTapped(_ tap: UITapGestureRecognizer) {
        guard let sw = tap.view else { return }
        readerThemeIndex = sw.tag
        // 刷新色块选中框（mask -> panel -> scroll）
        if let scroll = findScrollView(in: readerSettingsView) {
            for v in scroll.subviews {
                if let s = v as? UIView, s.tag < ReaderThemes.all.count {
                    s.layer.borderWidth = (s.tag == readerThemeIndex) ? 3 : 1
                    s.layer.borderColor = (s.tag == readerThemeIndex) ? UIColor.systemBlue.cgColor : UIColor.white.cgColor
                }
            }
        }
        applyReaderThemeChange()
    }

    // 在 mask/panel 层级里找第一个 UIScrollView（主题色块滚动区）
    private func findScrollView(in root: UIView?) -> UIScrollView? {
        guard let root = root else { return nil }
        for sub in root.subviews {
            if let sc = sub as? UIScrollView { return sc }
            if let found = findScrollView(in: sub) { return found }
        }
        return nil
    }

    // 主题/字号变化后统一重渲染
    private func applyReaderThemeChange() {
        // 更新容器/正文背景
        renderReaderContent(readerAttributed ?? NSAttributedString(string: ""))
    }

    // 顶栏 ⋮ -> 打开/关闭目录抽屉
    @objc private func readerShowDrawer() {
        if readerDrawerView == nil {
            buildReaderDrawerView()
        }
        let d = readerDrawerView!
        let showing = d.isHidden
        d.isHidden = !showing
        if showing { view.bringSubviewToFront(d) }
    }

    // 目录抽屉：侧滑面板，列出全部章节，点击跳转
    private func buildReaderDrawerView() {
        let drawer = UIView()
        drawer.backgroundColor = currentReaderTheme().backgroundColor
        drawer.translatesAutoresizingMaskIntoConstraints = false
        drawer.isHidden = true
        view.addSubview(drawer)
        NSLayoutConstraint.activate([
            drawer.topAnchor.constraint(equalTo: view.topAnchor),
            drawer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            drawer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            drawer.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.85)
        ])
        readerDrawerView = drawer

        let header = UILabel()
        header.text = "目录"
        header.font = .boldSystemFont(ofSize: 16)
        header.textColor = currentReaderTheme().textColor
        header.translatesAutoresizingMaskIntoConstraints = false
        drawer.addSubview(header)

        let closeBtn = UIButton(type: .system)
        closeBtn.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeBtn.tintColor = currentReaderTheme().textColor
        closeBtn.addTarget(self, action: #selector(readerShowDrawer), for: .touchUpInside)
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        drawer.addSubview(closeBtn)

        let tableView = UITableView()
        tableView.backgroundColor = currentReaderTheme().backgroundColor
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.tag = 7001
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "chap")
        drawer.addSubview(tableView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: drawer.topAnchor, constant: 16 + view.safeAreaInsets.top),
            header.leadingAnchor.constraint(equalTo: drawer.leadingAnchor, constant: 16),

            closeBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeBtn.trailingAnchor.constraint(equalTo: drawer.trailingAnchor, constant: -16),
            closeBtn.widthAnchor.constraint(equalToConstant: 40),
            closeBtn.heightAnchor.constraint(equalToConstant: 40),

            tableView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: drawer.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: drawer.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: drawer.bottomAnchor)
        ])
    }

    // 点击目录某章 -> 导航到该章
    private func readerJumpToChapter(index: Int) {
        guard index >= 0 && index < readerChapterIds.count else { return }
        let target = readerChapterIds[index]
        guard let info = readerLastData else { return }
        readerExpectedC = target
        readerLoadedC = nil
        let chapUrl = "https://sangtacviet.vip/truyen/\(info.h)/1/\(info.bookid)/\(target)/"
        appendDebugLog("[reader] jump to \(chapUrl)")
        readerDrawerView?.isHidden = true
        if let url = URL(string: chapUrl) {
            webView.load(URLRequest(url: url))
        }
    }

    // 翻页模式切换：分页(左右翻页) <-> 滚动(上下滑动)
    @objc private func readerToggleMode() {
        readerModeIsPaged.toggle()
        appendDebugLog("[reader] mode -> \(readerModeIsPaged ? "paged" : "scroll")")
        // 同步设置面板切换按钮文案（tag=9002）
        if let btn = findButton(tag: 9002, in: readerSettingsView) {
            btn.setTitle(readerModeIsPaged ? "左右翻页" : "上下滑动", for: .normal)
        }
        if let attr = readerAttributed {
            renderReaderContent(attr)
        }
    }

    private func findButton(tag: Int, in root: UIView?) -> UIButton? {
        guard let root = root else { return nil }
        for sub in root.subviews {
            if let b = sub as? UIButton, b.tag == tag { return b }
            if let found = findButton(tag: tag, in: sub) { return found }
        }
        return nil
    }

    // 顶栏 ⋮ 或底栏"设置"按钮 -> 显示设置面板
    @objc private func readerMenuTapped() {
        if readerSettingsView == nil {
            buildReaderSettingsView()
        }
        let s = readerSettingsView!
        let showing = s.isHidden
        s.isHidden = !showing
        if showing { view.bringSubviewToFront(s) }
    }

    // 点击正文中部切换顶/底栏显隐（安卓 menuTapMode）
    @objc private func readerToggleMenus() {
        readerMenusVisible.toggle()
        let target: CGFloat = readerMenusVisible ? 0 : -80
        UIView.animate(withDuration: 0.25) {
            if let tb = self.readerTopBar { tb.alpha = self.readerMenusVisible ? 1 : 0 }
            if let bb = self.readerBottomBar { bb.transform = CGAffineTransform(translationX: 0, y: self.readerMenusVisible ? 0 : 96) }
            _ = target
        }
        // 隐藏设置面板
        if let s = readerSettingsView, !s.isHidden { s.isHidden = true }
    }

    // 评论占位（安卓 btncomment）
    @objc private func readerCommentTapped() {
        appendDebugLog("[reader] comment tapped")
    }

    // 朗读占位（安卓 btnspeak）
    @objc private func readerSpeakTapped() {
        appendDebugLog("[reader] speak tapped")
    }

    // 进度条拖动 -> 跳到章节对应位置（安卓 gotoProgress）
    @objc private func readerProgressChanged(_ slider: UISlider) {
        let p = CGFloat(slider.value) / 1000.0
        appendDebugLog("[reader] progress \(Int(slider.value))")
        // 滚动模式：滚动到正文对应位置
        guard let tv = readerTextView, tv.isScrollEnabled else { return }
        let h = tv.contentSize.height - tv.bounds.height
        if h > 0 {
            let offset = CGPoint(x: 0, y: h * p)
            tv.setContentOffset(offset, animated: false)
        }
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

    // 上一章/下一章：优先用章节列表(readerChapterIds)定位，其次 readchapter 的 prev/next，最后 c±1
    private func readerGo(delta: Int) {
        guard let info = readerLastData else {
            appendDebugLog("[reader] no last data for nav")
            return
        }
        appendDebugLog("[reader] nav(+\(delta)) c=\(info.c) chapterIds=\(readerChapterIds.count) prev=\(readerPrevC) next=\(readerNextC)")
        var newC: String?
        // 1) 章节列表顺序导航（最可靠：getchapterlist 提供的真实有序章节）
        if !readerChapterIds.isEmpty {
            if let idx = readerChapterIds.firstIndex(of: info.c) {
                let ni = idx + delta
                if ni >= 0 && ni < readerChapterIds.count {
                    newC = readerChapterIds[ni]
                } else {
                    appendDebugLog("[reader] nav out of range idx=\(idx) ni=\(ni)")
                }
            } else {
                appendDebugLog("[reader] c=\(info.c) not in chapterIds, try fallback")
            }
        }
        // 2) readchapter 提供的 prev/next（仅当列表未命中时）
        if newC == nil {
            let direct = delta < 0 ? readerPrevC : readerNextC
            if !direct.isEmpty { newC = direct }
        }
        if newC == nil {
            // 3) 兜底 c±1
            var cVal = Int64(info.c) ?? 0
            cVal += Int64(delta)
            newC = String(cVal)
        }
        guard let target = newC, !target.isEmpty else {
            appendDebugLog("[reader] no nav target")
            return
        }
        appendDebugLog("[reader] nav to c=\(target) h=\(info.h) bookid=\(info.bookid)")
        // 更新期望章节，忽略旧章节迟到上报；清空已加载标记以便新章节可 present
        readerExpectedC = target
        readerLoadedC = nil
        readerLastData = (info.h, info.bookid, target)
        // 立即显示加载占位，避免闪现旧章
        presentReader(html: "<p>加载中…</p>", title: "")
        // 占位不算已加载，确保真实正文(c=target)能正常渲染
        readerLoadedC = nil
        // v23：不整页导航章节页（避免卡顿/返回错/竞态）。在当前页内直接发 readchapter
        // XHR（会话已建立，页内 code:0 可行），由已注入的 bridgeJS readchapter 拦截
        // 提取正文并上报 -> 原生渲染。webview 地址不变 -> 返回自然回目录、无重载卡顿。
        let h = info.h, bi = info.bookid, c = target
        let js = """
        (function(){
            try {
                var h='\(h)', i='\(bi)', c='\(c)';
                var u='/index.php?bookid='+encodeURIComponent(i)+'&h='+encodeURIComponent(h)+'&c='+encodeURIComponent(c)+'&ngmar=readc&sajax=readchapter&sty=1&exts=';
                var x=new XMLHttpRequest();
                x._dbgUrl=u;
                x.open('POST', u);
                x.setRequestHeader('Content-Type','application/x-www-form-urlencoded');
                x.onload=function(){
                    try{
                        var o=JSON.parse(x.responseText);
                        var m='nav-readc code='+(o&&o.code)+' len='+(x.responseText||'').length;
                        if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.dbg){
                            window.webkit.messageHandlers.dbg.postMessage({tag:'nav-readc',msg:m});
                        }
                    }catch(e){}
                };
                x.send('');
            }catch(e){}
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    @objc private func readerFontDown() {
        adjustReaderFont(delta: -2)
    }

    @objc private func readerFontUp() {
        adjustReaderFont(delta: 2)
    }

    private func adjustReaderFont(delta: CGFloat) {
        readerFontSize = max(12, min(32, readerFontSize + delta))
        appendDebugLog("[reader] font=\(readerFontSize)")
        // 同步设置面板字号数字（mask 层级递归查找 tag==9001）
        findLabel(tag: 9001, in: readerSettingsView)?.text = "\(Int(readerFontSize))"
        if !readerRawHTML.isEmpty {
            let newAttr = htmlToAttributed(readerRawHTML)
            readerAttributed = newAttr
            renderReaderContent(newAttr)
        }
    }

    private func findLabel(tag: Int, in root: UIView?) -> UILabel? {
        guard let root = root else { return nil }
        for sub in root.subviews {
            if let l = sub as? UILabel, l.tag == tag { return l }
            if let found = findLabel(tag: tag, in: sub) { return found }
        }
        return nil
    }

    @objc private func readerNightToggle() {
        // 夜间 = 深色主题（index 10, 11 为深底）
        readerThemeIndex = 10
        appendDebugLog("[reader] night theme idx=\(readerThemeIndex)")
        if let attr = readerAttributed { renderReaderContent(attr) }
    }

    @objc private func readerDayMode() {
        // 白天 = 浅米色主题（index 0）
        readerThemeIndex = 0
        appendDebugLog("[reader] day theme idx=\(readerThemeIndex)")
        if let attr = readerAttributed { renderReaderContent(attr) }
    }

    private func htmlEscape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        return out
    }

    // ===== UIPageViewControllerDataSource (分页阅读) =====
    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let pvc = viewController as? ReaderPageViewController else { return nil }
        return makePageVC(index: pvc.pageIndex - 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let pvc = viewController as? ReaderPageViewController else { return nil }
        return makePageVC(index: pvc.pageIndex + 1)
    }

    // ===== UITableViewDataSource / Delegate（目录抽屉）=====
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return readerChapterTitles.isEmpty ? readerChapterIds.count : readerChapterTitles.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "chap", for: indexPath)
        let i = indexPath.row
        let title: String
        if !readerChapterTitles.isEmpty && i < readerChapterTitles.count {
            title = readerChapterTitles[i].isEmpty ? "Chương \(readerChapterIds[i])" : readerChapterTitles[i]
        } else if i < readerChapterIds.count {
            title = "Chương \(readerChapterIds[i])"
        } else {
            title = "Chương \(i + 1)"
        }
        cell.textLabel?.text = title
        cell.textLabel?.font = .systemFont(ofSize: 14)
        cell.textLabel?.numberOfLines = 1
        cell.backgroundColor = currentReaderTheme().backgroundColor
        cell.textLabel?.textColor = currentReaderTheme().textColor
        // 高亮当前章节
        if let info = readerLastData, i < readerChapterIds.count, readerChapterIds[i] == info.c {
            cell.textLabel?.textColor = .systemBlue
            cell.textLabel?.font = .boldSystemFont(ofSize: 14)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        readerJumpToChapter(index: indexPath.row)
    }

}

// 分页阅读的一页：原生 UITextView 显示一段富文本
private class ReaderPageViewController: UIViewController {
    var pageIndex: Int = 0
    var attributedText: NSAttributedString? = nil
    var pageBackground: UIColor = UIColor(red: 0.965, green: 0.945, blue: 0.91, alpha: 1)
    var fontSize: CGFloat = 18
    var textColor: UIColor = .black

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = pageBackground
        let tv = UITextView()
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = pageBackground
        tv.textColor = textColor
        tv.attributedText = attributedText
        tv.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        tv.textContainer.lineFragmentPadding = 0
        view.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: view.topAnchor),
            tv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tv.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
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
