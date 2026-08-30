import UIKit
import WebKit

class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKURLSchemeHandler {

    var webView: WKWebView!

    // 原生网络层兜底：服务器要求 GET 请求必须携带 Referer 头，否则返回空体(Content-Length: 0)，
    // 前端会误判为 "Kết nối tới máy chủ thất bại"。
    // 纯 Web 模式下 WKWebView 的同源 XHR 不携带 Referer（而安卓用 CapacitorHttp 原生层显式
    // 附加 "Referer": document.referrer || location.href，见 app.v2.js getCapacitor）。
    // JS 无法通过 XHR 设置 Referer(forbidden header)，因此用 WKURLSchemeHandler 接管 https
    // 请求，在原生层强制附加 Referer 后经 URLSession 转发，等价于安卓的原生网络层。
    private var stvHosts: Set<String> = ["sangtacviet.com", "sangtacviet.app", "sangtacviet.vip", "dns1.stv-appdomain-00000001.org"]
    private var activeTasks: [String: URLSessionDataTask] = [:]
    private var refererBase = "https://sangtacviet.com"
    private lazy var netSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        return URLSession(configuration: cfg)
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupWebView()
        loadApp()
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()

        // 注册 https scheme 处理器：拦截所有 https 请求，原生附加 Referer 后转发。
        config.setURLSchemeHandler(self, forURLScheme: "https")

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
        // 记录当前页面 URL 作为 Referer 基准（供原生网络层附加）
        if let url = webView.url?.absoluteString, !url.isEmpty {
            refererBase = url
        }
        // 触发一次 resize，让前端重新测量 --vh 等视口变量
        webView.evaluateJavaScript("window.dispatchEvent(new Event('resize'));", completionHandler: nil)
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        var request = urlSchemeTask.request
        let key = String(urlSchemeTask.hash)

        guard let host = request.url?.host?.lowercased(), stvHosts.contains(host) else {
            // 非 STV 域名：直接转发，不附加头
            dispatchTask(request, key: key, urlSchemeTask: urlSchemeTask)
            return
        }

        // STV 域名：强制附加 Referer（服务器对 GET 强制要求 Referer，否则返回空体；
        // 等价于安卓 CapacitorHttp 的 getCapacitor 显式附加 Referer）。Cookie 由下方从
        // CookieStore 读取后附加。
        if request.value(forHTTPHeaderField: "Referer") == nil {
            request.setValue(refererBase, forHTTPHeaderField: "Referer")
        }

        // 异步从 CookieStore 读取登录态 Cookie，组装成 Cookie 头后转发
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        cookieStore.getAllCookies { [weak self] cookies in
            guard let self = self else {
                self?.dispatchTask(request, key: key, urlSchemeTask: urlSchemeTask)
                return
            }
            var items: [String] = []
            if let cached = self.cachedCookies[host] { items.append(cached) }
            for c in cookies where c.domain.lowercased().contains(host) || host.contains(c.domain.lowercased()) {
                items.append("\(c.name)=\(c.value)")
            }
            if !items.isEmpty {
                request.setValue(items.joined(separator: "; "), forHTTPHeaderField: "Cookie")
            }
            self.dispatchTask(request, key: key, urlSchemeTask: urlSchemeTask)
        }
    }

    private func dispatchTask(_ request: URLRequest, key: String, urlSchemeTask: WKURLSchemeTask) {
        // WKURLSchemeTask 的 didReceive/didFinish 必须在主线程调用，URLSession 的
        // completion handler 默认在后台队列，因此统一切回主线程处理响应。
        let task = netSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.activeTasks[key] = nil
                if let error = error {
                    urlSchemeTask.didFailWithError(error)
                    return
                }
                guard let data = data else {
                    urlSchemeTask.didFailWithError(NSError(domain: "SangTacReader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty response"]))
                    return
                }
                if let httpResponse = response as? HTTPURLResponse {
                    // 把 Set-Cookie 写回 WKWebView 的 CookieStore，保证登录态在 Web 侧可见
                    self?.storeCookies(from: httpResponse)
                    // URLSession 会自动解压 gzip/br，但响应头仍保留 Content-Encoding，
                    // 若不移除，WKWebView 会对已解压的 body 再次解压导致乱码/失败。
                    urlSchemeTask.didReceive(self?.fixedResponse(httpResponse) ?? httpResponse)
                } else {
                    urlSchemeTask.didReceive(URLResponse(url: request.url!, mimeType: nil, expectedContentLength: data.count, textEncodingName: nil))
                }
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            }
        }
        activeTasks[key] = task
        task.resume()
    }

    // 重建响应头：移除 Content-Encoding 及 hop-by-hop 头（body 已被 URLSession 解压）。
    private func fixedResponse(_ response: HTTPURLResponse) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let k = key as? String, let v = value as? String else { continue }
            let lower = k.lowercased()
            if lower == "content-encoding" || lower == "transfer-encoding" || lower == "connection" {
                continue
            }
            headers[k] = v
        }
        if let url = response.url {
            return HTTPURLResponse(url: url,
                                   statusCode: response.statusCode,
                                   httpVersion: "HTTP/1.1",
                                   headerFields: headers) ?? response
        }
        return response
    }

    // 缓存各域 Cookie 文本，供请求附加
    private var cachedCookies: [String: String] = [:]

    private func storeCookies(from response: HTTPURLResponse) {
        guard let url = response.url, let host = url.host?.lowercased() else { return }
        guard let allHeaders = response.allHeaderFields as? [String: String] else { return }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: allHeaders, for: url)
        guard !cookies.isEmpty else { return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        var items: [String] = []
        for cookie in cookies {
            store.setCookie(cookie) { }
            items.append("\(cookie.name)=\(cookie.value)")
        }
        if let existing = cachedCookies[host] {
            cachedCookies[host] = existing + "; " + items.joined(separator: "; ")
        } else {
            cachedCookies[host] = items.joined(separator: "; ")
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let key = String(urlSchemeTask.hash)
        activeTasks[key]?.cancel()
        activeTasks[key] = nil
    }
}
