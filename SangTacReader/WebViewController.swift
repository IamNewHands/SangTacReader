import UIKit
import WebKit

class WebViewController: UIViewController, WKNavigationDelegate {

    var webView: WKWebView!
    let bookURL = URL(string: "https://sangtacviet.vip/")!

    override func viewDidLoad() {
        super.viewDidLoad()
        setupWebView()
        loadSite()
    }

    private func setupWebView() {
        // 注入 "阅读模式" 脚本
        let readerJS = loadScript("reader")
        let userScript = WKUserScript(source: readerJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false)

        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.addUserScript(userScript)
        config.userContentController = controller

        // 允许无痕模式外链映射
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func loadScript(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js") else {
            print("⚠️ 未找到脚本 \(name).js")
            return ""
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func loadSite() {
        var req = URLRequest(url: bookURL)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        webView.load(req)
    }

    // 让站内跳转都在 webView 内
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url {
            // 站内/同域 保留；外链(广告等)用系统浏览器
            if url.host == "sangtacviet.vip" || url.host == "sangtacviet.app" || url.host == "sangtacviet.com" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        } else {
            decisionHandler(.allow)
        }
    }
}