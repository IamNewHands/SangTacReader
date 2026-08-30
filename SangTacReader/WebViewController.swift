import UIKit
import WebKit

class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    var webView: WKWebView!

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
        loadApp()
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
                            if (typeof url === 'string' && url.indexOf('://') === -1) {
                                url = curOrigin + (url.charAt(0) === '/' ? url : '/' + url);
                            }
                            if (typeof url === 'string') {
                                var u = new URL(url, window.location.href);
                                if (stvHosts.indexOf(u.hostname) !== -1 && u.origin !== curOrigin) {
                                    url = curOrigin + u.pathname + u.search;
                                }
                            }
                        } catch (e) {}
                        return origOpen.apply(this, arguments);
                    };
                } catch (e) {}
            })();

            // 从源头强制保持同源：覆盖 networkManagerXHR 的域存活判断与 bestDomain，
            // 让 fullUrl() 不再把请求切到镜像域名，从而请求从一开始就是同源的完整 URL，
            // WKWebView 会自动携带完整 Referer。等 app.v2.js 初始化 networkManagerXHR 后覆盖。
            (function() {
                try {
                    var applied = false;
                    function applyPatch() {
                        if (applied) return;
                        try {
                            if (typeof window.app !== 'undefined' &&
                                window.app && window.app.net &&
                                window.app.net.networkManagerXHR) {
                                var nm = window.app.net.networkManagerXHR;
                                var curOrigin = window.location.origin;
                                // isDomainAlive 只信任当前 origin，其余镜像域名一律视为不可用，
                                // 使 fullUrl() 的 baseDomain 保持为 window.location.origin。
                                nm.isDomainAlive = function(domain) {
                                    try {
                                        if (domain === curOrigin) return true;
                                    } catch (e) {}
                                    return false;
                                };
                                // bestDomain 直接返回当前 origin，绝不切镜像域名。
                                nm.bestDomain = function() {
                                    return curOrigin;
                                };
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
        })();
        """
        let bridgeScript = WKUserScript(source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        controller.addUserScript(bridgeScript)

        config.userContentController = controller
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 SangTacVietApp/1.2.17"
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
}
