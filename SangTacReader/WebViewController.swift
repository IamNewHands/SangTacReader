import UIKit
import WebKit
import AVFoundation

class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, AVSpeechSynthesizerDelegate {

    var webView: WKWebView!
    let synthesizer = AVSpeechSynthesizer()
    let impactGenerator = UIImpactFeedbackGenerator(style: .light)
    var isStatusBarHidden = false

    override var prefersStatusBarHidden: Bool {
        return isStatusBarHidden
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        synthesizer.delegate = self
        setupAudioSession()
        setupWebView()
        loadApp()
    }

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AudioSession setup failed: \(error)")
        }
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()

        // 允许 Cookie 和本地持久化
        config.websiteDataStore = WKWebsiteDataStore.default()

        // 注册 JSBridge Handler
        controller.add(self, name: "bridge")
        controller.add(self, name: "cordovaExec")

        // 注入桥接适配脚本
        let bridgeJS = """
        window.isIOSNativeApp = true;
        
        // 保证 Capacitor.Plugins 和 Capacitor.CapacitorHttp 存在
        window.Capacitor = window.Capacitor || {};
        window.Capacitor.Plugins = window.Capacitor.Plugins || {};
        
        // Cordova 插件桥接
        if (!window.cordova) {
            window.cordova = {
                exec: function(success, fail, service, action, args) {
                    var callbackId = 'cb_' + Date.now() + '_' + Math.floor(Math.random()*10000);
                    window._callbacks = window._callbacks || {};
                    window._callbacks[callbackId] = { success: success, fail: fail };
                    
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.cordovaExec) {
                        window.webkit.messageHandlers.cordovaExec.postMessage({
                            service: service,
                            action: action,
                            args: args || [],
                            callbackId: callbackId
                        });
                    }
                }
            };
        }

        // 快捷分发原生回执
        window._nativeCallback = function(callbackId, isSuccess, data) {
            if (window._callbacks && window._callbacks[callbackId]) {
                if (isSuccess) {
                    if (window._callbacks[callbackId].success) window._callbacks[callbackId].success(data);
                } else {
                    if (window._callbacks[callbackId].fail) window._callbacks[callbackId].fail(data);
                }
                delete window._callbacks[callbackId];
            }
        };
        """
        let bridgeScript = WKUserScript(source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        controller.addUserScript(bridgeScript)

        config.userContentController = controller
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.allowsInlineMediaPlayback = true

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
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
        let targetURL = URL(string: "https://sangtacviet.vip/app.v2.php") ?? URL(string: "https://sangtacviet.vip/")!
        var request = URLRequest(url: targetURL)
        request.setValue("https://sangtacviet.vip", forHTTPHeaderField: "Referer")
        webView.load(request)
    }

    // MARK: - WKScriptMessageHandler
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "cordovaExec", let body = message.body as? [String: Any] {
            handleCordovaExec(body: body)
        } else if message.name == "bridge", let body = message.body as? [String: Any] {
            handleCapacitorBridge(body: body)
        }
    }

    private func handleCordovaExec(body: [String: Any]) {
        guard let service = body["service"] as? String,
              let action = body["action"] as? String,
              let callbackId = body["callbackId"] as? String else { return }
        let args = body["args"] as? [Any] ?? []

        switch service {
        case "TTS":
            handleTTS(action: action, args: args, callbackId: callbackId)
        case "NativeClick":
            impactGenerator.impactOccurred()
            sendCordovaResult(callbackId: callbackId, success: true, data: nil)
        case "AndroidFullScreen":
            handleFullScreen(action: action, callbackId: callbackId)
        default:
            sendCordovaResult(callbackId: callbackId, success: true, data: nil)
        }
    }

    private func handleCapacitorBridge(body: [String: Any]) {
        guard let pluginId = body["pluginId"] as? String,
              let methodName = body["methodName"] as? String,
              let callbackId = body["callbackId"] as? String else { return }
        let options = body["options"] as? [String: Any] ?? [:]

        if pluginId == "Haptics" || pluginId == "NativeClick" {
            impactGenerator.impactOccurred()
            sendCapacitorResult(callbackId: callbackId, pluginId: pluginId, methodName: methodName, success: true, data: [:])
        } else if pluginId == "StatusBar" {
            if methodName == "hide" {
                isStatusBarHidden = true
                setNeedsStatusBarAppearanceUpdate()
            } else if methodName == "show" {
                isStatusBarHidden = false
                setNeedsStatusBarAppearanceUpdate()
            }
            sendCapacitorResult(callbackId: callbackId, pluginId: pluginId, methodName: methodName, success: true, data: [:])
        } else {
            sendCapacitorResult(callbackId: callbackId, pluginId: pluginId, methodName: methodName, success: true, data: [:])
        }
    }

    // MARK: - TTS 处理 (原生 AVSpeechSynthesizer)
    private func handleTTS(action: String, args: [Any], callbackId: String) {
        if action == "speak" {
            if synthesizer.isSpeaking {
                synthesizer.stopSpeaking(at: .immediate)
            }
            var textToSpeak = ""
            var rate: Float = AVSpeechUtteranceDefaultSpeechRate
            var lang = "vi-VN"

            if let firstArg = args.first as? [String: Any] {
                textToSpeak = firstArg["text"] as? String ?? ""
                if let rateVal = firstArg["rate"] as? Double {
                    rate = Float(rateVal) * AVSpeechUtteranceDefaultSpeechRate
                }
                if let locale = firstArg["locale"] as? String {
                    lang = locale
                }
            } else if let str = args.first as? String {
                textToSpeak = str
            }

            let utterance = AVSpeechUtterance(string: textToSpeak)
            utterance.voice = AVSpeechSynthesisVoice(language: lang) ?? AVSpeechSynthesisVoice(language: "vi-VN")
            utterance.rate = max(AVSpeechUtteranceMinimumSpeechRate, min(rate, AVSpeechUtteranceMaximumSpeechRate))
            utterance.pitchMultiplier = 1.0
            utterance.volume = 1.0

            synthesizer.speak(utterance)
            sendCordovaResult(callbackId: callbackId, success: true, data: nil)
        } else if action == "stop" {
            if synthesizer.isSpeaking {
                synthesizer.stopSpeaking(at: .immediate)
            }
            sendCordovaResult(callbackId: callbackId, success: true, data: nil)
        } else if action == "getVoices" {
            let voices = AVSpeechSynthesisVoice.speechVoices().map { ["name": $0.name, "language": $0.language, "identifier": $0.identifier] }
            sendCordovaResult(callbackId: callbackId, success: true, data: voices)
        } else {
            sendCordovaResult(callbackId: callbackId, success: true, data: nil)
        }
    }

    private func handleFullScreen(action: String, callbackId: String) {
        if action == "immersiveMode" || action == "leanMode" {
            isStatusBarHidden = true
            UIView.animate(withDuration: 0.25) {
                self.setNeedsStatusBarAppearanceUpdate()
            }
        } else if action == "showSystemUI" || action == "resetScreen" {
            isStatusBarHidden = false
            UIView.animate(withDuration: 0.25) {
                self.setNeedsStatusBarAppearanceUpdate()
            }
        }
        sendCordovaResult(callbackId: callbackId, success: true, data: nil)
    }

    private func sendCordovaResult(callbackId: String, success: Bool, data: Any?) {
        let jsonStr: String
        if let data = data, let jsonData = try? JSONSerialization.data(withJSONObject: data), let str = String(data: jsonData, encoding: .utf8) {
            jsonStr = str
        } else {
            jsonStr = "null"
        }
        let js = "window._nativeCallback('\(callbackId)', \(success), \(jsonStr));"
        DispatchQueue.main.async {
            self.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func sendCapacitorResult(callbackId: String, pluginId: String, methodName: String, success: Bool, data: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }
        let js = "if (window.Capacitor && window.Capacitor.fromNative) { window.Capacitor.fromNative({ callbackId: '\(callbackId)', pluginId: '\(pluginId)', methodName: '\(methodName)', success: \(success), data: \(jsonStr) }); }"
        DispatchQueue.main.async {
            self.webView.evaluateJavaScript(js, completionHandler: nil)
        }
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
        // 修复语言与翻译以及登录 Cookie 刷新
        let fixScript = """
        (function() {
            // 确保 localStorage 中语言设置正确生效
            var savedLang = localStorage.getItem('stv_lang') || localStorage.getItem('lang');
            if (savedLang && window.setLang) {
                try { window.setLang(savedLang);
                } catch(e) {}
            }
        })();
        """
        webView.evaluateJavaScript(fixScript, completionHandler: nil)
    }
}
