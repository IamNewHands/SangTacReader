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

        // 预设 Capacitor 原生环境和 Cordova TTS 原生插件
        let bridgeJS = """
        (function() {
            // 1. 注入 iOS WebKit CSS 视口与安全区规则 (非侵入式)
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

            // 动态设置 --vh 变量
            function updateVH() {
                var vh = (window.innerHeight || document.documentElement.clientHeight) * 0.01;
                document.documentElement.style.setProperty('--vh', vh + 'px');
                document.documentElement.style.setProperty('--vh100', (window.innerHeight || document.documentElement.clientHeight) + 'px');
                document.documentElement.style.setProperty('--vh100subtop', (window.innerHeight || document.documentElement.clientHeight) + 'px');
            }
            updateVH();
            window.addEventListener('resize', updateVH);
            window.addEventListener('orientationchange', updateVH);

            // 2. 注入完整健壮的 Capacitor 桥接 (包含 fromNative 与各核心插件)
            window.Capacitor = window.Capacitor || {};
            window.Capacitor.isNative = true;
            window.Capacitor.isPluginAvailable = function(name) {
                // 不提供原生 Http 插件，让前端天然使用原生 XHR/fetch 请求真实的服务器网络与 Cookie
                if (name === 'Http') return false;
                return true;
            };
            window.Capacitor.fromNative = function(result) {
                // 默认的 fromNative 回执处理
            };
            window.Capacitor.Plugins = window.Capacitor.Plugins || {};

            // Capacitor App 插件 (支持 addListener, SyncCookie, getInfo, exitApp)
            var appListeners = {};
            window.Capacitor.Plugins.App = {
                addListener: function(eventName, callback) {
                    if (!appListeners[eventName]) appListeners[eventName] = [];
                    appListeners[eventName].push(callback);
                    return Promise.resolve({
                        remove: function() {
                            if (appListeners[eventName]) {
                                appListeners[eventName] = appListeners[eventName].filter(function(cb) { return cb !== callback; });
                            }
                        }
                    });
                },
                removeAllListeners: function(eventName) {
                    if (eventName) {
                        delete appListeners[eventName];
                    } else {
                        appListeners = {};
                    }
                    return Promise.resolve();
                },
                SyncCookie: function() {
                    // 同步 Cookie
                    return Promise.resolve();
                },
                exitApp: function() {
                    return Promise.resolve();
                },
                getInfo: function() {
                    return Promise.resolve({
                        name: "SangTacReader",
                        id: "com.sangtacviet.mobilereader",
                        build: "1",
                        version: "1.2.17"
                    });
                },
                getState: function() {
                    return Promise.resolve({ isActive: true });
                }
            };

            // 派发原生 BackButton 事件
            window._fireBackButton = function(canGoBack) {
                if (appListeners['backButton']) {
                    appListeners['backButton'].forEach(function(cb) {
                        try { cb({ canGoBack: !!canGoBack }); } catch(e) {}
                    });
                } else {
                    if (window.history && window.history.length > 1) {
                        window.history.back();
                    }
                }
            };

            // Capacitor Haptics 插件 (触觉反馈)
            window.Capacitor.Plugins.Haptics = {
                impact: function(options) {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge) {
                        window.webkit.messageHandlers.bridge.postMessage({
                            pluginId: 'Haptics',
                            methodName: 'impact',
                            options: options || {}
                        });
                    }
                    return Promise.resolve();
                },
                vibrate: function() {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge) {
                        window.webkit.messageHandlers.bridge.postMessage({
                            pluginId: 'Haptics',
                            methodName: 'vibrate',
                            options: {}
                        });
                    }
                    return Promise.resolve();
                },
                notification: function() { return Promise.resolve(); },
                selectionStart: function() { return Promise.resolve(); },
                selectionChanged: function() { return Promise.resolve(); },
                selectionEnd: function() { return Promise.resolve(); }
            };

            // Capacitor StatusBar 插件
            window.Capacitor.Plugins.StatusBar = {
                hide: function() {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge) {
                        window.webkit.messageHandlers.bridge.postMessage({ pluginId: 'StatusBar', methodName: 'hide' });
                    }
                    return Promise.resolve();
                },
                show: function() {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge) {
                        window.webkit.messageHandlers.bridge.postMessage({ pluginId: 'StatusBar', methodName: 'show' });
                    }
                    return Promise.resolve();
                },
                setStyle: function(options) {
                    return Promise.resolve();
                },
                setBackgroundColor: function(options) {
                    return Promise.resolve();
                },
                setOverlaysWebView: function(options) {
                    return Promise.resolve();
                },
                getInfo: function() {
                    return Promise.resolve({ visible: true, overlays: false });
                }
            };

            // Capacitor Device 插件
            window.Capacitor.Plugins.Device = {
                getInfo: function() {
                    return Promise.resolve({
                        model: "iPhone",
                        platform: "ios",
                        operatingSystem: "ios",
                        osVersion: "17.0",
                        manufacturer: "Apple",
                        isVirtual: false,
                        webViewVersion: "605.1.15"
                    });
                },
                getId: function() {
                    return Promise.resolve({ uuid: "ios-device-uuid" });
                },
                getBatteryInfo: function() {
                    return Promise.resolve({ batteryLevel: 1.0, isCharging: false });
                },
                getLanguageCode: function() {
                    return Promise.resolve({ value: "vi" });
                },
                getLanguageTag: function() {
                    return Promise.resolve({ value: "vi-VN" });
                }
            };

            // Capacitor Keyboard 插件
            window.Capacitor.Plugins.Keyboard = {
                show: function() { return Promise.resolve(); },
                hide: function() { return Promise.resolve(); },
                setAccessoryBarVisible: function() { return Promise.resolve(); },
                setScroll: function() { return Promise.resolve(); }
            };

            // Capacitor SplashScreen 插件
            window.Capacitor.Plugins.SplashScreen = {
                hide: function() { return Promise.resolve(); },
                show: function() { return Promise.resolve(); }
            };

            // Capacitor Toast 插件
            window.Capacitor.Plugins.Toast = {
                show: function(options) {
                    if (window.M && window.M.toast && options && options.text) {
                        try { window.M.toast({ html: options.text }); } catch(e) {}
                    }
                    return Promise.resolve();
                }
            };

            // Capacitor Browser 插件
            window.Capacitor.Plugins.Browser = {
                open: function(options) {
                    if (options && options.url) window.open(options.url, '_blank');
                    return Promise.resolve();
                },
                close: function() { return Promise.resolve(); }
            };

            // 3. 兼容 Cordova 经典 exec 桥接
            if (!window.cordova) {
                window.cordova = {
                    exec: function(success, fail, service, action, args) {
                        var callbackId = 'cb_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);
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
                    },
                    plugins: {
                        tts: {
                            speak: function(options, success, fail) {
                                window.cordova.exec(success, fail, "TTS", "speak", [options]);
                            },
                            stop: function(success, fail) {
                                window.cordova.exec(success, fail, "TTS", "stop", []);
                            },
                            getVoices: function(success, fail) {
                                window.cordova.exec(success, fail, "TTS", "getVoices", []);
                            }
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
                UIView.animate(withDuration: 0.25) {
                    self.setNeedsStatusBarAppearanceUpdate()
                }
            } else if methodName == "show" {
                isStatusBarHidden = false
                UIView.animate(withDuration: 0.25) {
                    self.setNeedsStatusBarAppearanceUpdate()
                }
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
        // 修复语言与翻译以及登录 Cookie 刷新与布局重新测量
        let fixScript = """
        (function() {
            // 触发一次 resize 计算
            if (window.dispatchEvent) {
                window.dispatchEvent(new Event('resize'));
            }
            
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
