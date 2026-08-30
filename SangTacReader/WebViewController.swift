import UIKit
import WebKit

class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    var webView: WKWebView!

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
            // 把请求改回当前页面域后变成同域请求，无 preflight，x-stv-transport 头正常发送。
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
