import Foundation
import Capacitor
import UIKit
import WebKit

/**
 SangTacAppPlugin — replaces @capacitor/app on iOS.

 Why not the official plugin: the site's JS calls
 `Capacitor.Plugins.App.SyncCookie()`, a method the Android build added to its
 patched App plugin. Two Capacitor plugins cannot share the jsName "App", so we
 provide our own plugin covering everything the frontend uses:
   exitApp, getInfo, getLaunchUrl, getState, addListener("appStateChange"),
   addListener("backButton")  +  SyncCookie

 addListener/removeAllListeners are inherited from CAPPlugin (declared in
 CAPPlugin.h) and must NOT be redeclared here; we only register observers in
 load() and call notifyListeners().

 SyncCookie is an acknowledged no-op because SangTacHttpPlugin already bridges
 WKWebsiteDataStore cookies (including httpOnly ones) into every native request.
 */
@objc(SangTacAppPlugin)
public class SangTacAppPlugin: CAPPlugin, CAPBridgedPlugin {

    public let identifier = "SangTacAppPlugin"
    public let jsName = "App"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "exitApp", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getInfo", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getLaunchUrl", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "SyncCookie", returnType: CAPPluginReturnPromise)
    ]

    private var observers: [NSObjectProtocol] = []

    override public func load() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                           object: nil, queue: OperationQueue.main) { [weak self] _ in
            self?.notifyListeners("appStateChange", data: ["isActive": true])
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification,
                                           object: nil, queue: OperationQueue.main) { [weak self] _ in
            self?.notifyListeners("appStateChange", data: ["isActive": false])
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                           object: nil, queue: OperationQueue.main) { [weak self] _ in
            self?.notifyListeners("pause", data: nil)
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                           object: nil, queue: OperationQueue.main) { [weak self] _ in
            self?.notifyListeners("resume", data: nil)
        })

        installDocumentStartShim()
    }

    // MARK: - Site compatibility

    /**
     The site's frontend calls globals that the Android APK gets from Cordova
     plugins. On iOS those globals are missing, and the site references them
     *unguarded* on hot paths, so one missing global aborts the whole handler.

     Concretely (book-row click handler in the list module):

         e.addEventListener("click", function () {
             app.platform.nativeClick();                       // -> nativeclick.trigger()
             app.fun.openBookWithData(this.data.lid, this.data);
         });

     `nativeclick` comes from cordova-plugin-nativeclicksound in the APK. Without
     it the first line throws ReferenceError and the book never opens — the
     "list loads but tapping a novel does nothing" symptom.

     Injected at document start so the globals exist before any page script runs.
     `TTS` is intentionally an empty object: the site only probes it as
     `if (TTS.updateMediaSession)` for Android media-session integration, so an
     empty object makes those branches skip cleanly instead of throwing.

     The same script installs a diagnostics panel (window.__stvDiag). A
     sideloaded iOS build has no console we can read, so it captures
     window.onerror, unhandledrejection, all console output and every
     SangTacHttpPlugin request. It stays hidden until a line is logged with tag
     ERR, then opens itself; triple-tap the top-left corner to toggle it and
     CLOSE to dismiss. SangTacHttpPlugin pushes request lines in via
     evaluateJavaScript.
     */
    private func installDocumentStartShim() {
        let source = """
        (function () {
            if (window.__stvIOSCompatInstalled) { return; }
            window.__stvIOSCompatInstalled = true;
            if (typeof window.nativeclick === 'undefined') {
                window.nativeclick = {
                    trigger: function () {},
                    watch: function () {}
                };
            }
            if (typeof window.TTS === 'undefined') {
                window.TTS = {};
            }

            if (window.__stvDiagInstalled) { return; }
            window.__stvDiagInstalled = true;
            var NL = String.fromCharCode(10);
            var MAX = 400;
            var lines = [];
            var panel = null;
            var list = null;
            var pending = false;

            function fmt(v) {
                try {
                    if (typeof v === 'string') { return v; }
                    if (v && v.message) { return v.message; }
                    if (typeof v === 'object') { return JSON.stringify(v); }
                    return String(v);
                } catch (e) {
                    return '<unprintable>';
                }
            }

            function stamp() {
                var d = new Date();
                function p(n) { return ('0' + n).slice(-2); }
                return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
            }

            function build() {
                if (panel) { return !!panel.parentNode; }
                panel = document.createElement('div');
                panel.style.cssText = 'position:fixed;left:0;right:0;bottom:0;height:60%;'
                    + 'z-index:2147483647;background:rgba(0,0,0,0.93);color:#5f5;'
                    + 'font:11px/1.35 Menlo,monospace;padding:26px 8px 8px;overflow:auto;'
                    + '-webkit-user-select:text;user-select:text;white-space:pre-wrap;'
                    + 'word-break:break-all;display:none;';
                var bar = document.createElement('div');
                bar.style.cssText = 'position:absolute;top:0;left:0;right:0;height:24px;background:#111;text-align:right;';
                var btn = document.createElement('button');
                btn.textContent = 'CLOSE';
                btn.style.cssText = 'font:11px monospace;padding:2px 10px;margin:2px 6px;';
                btn.onclick = function (e) { e.stopPropagation(); e.preventDefault(); hide(); };
                bar.appendChild(btn);
                panel.appendChild(bar);
                list = document.createElement('div');
                panel.appendChild(list);
                var host = document.body || document.documentElement;
                if (!host) { return false; }
                host.appendChild(panel);
                return true;
            }

            function render() {
                if (list) { list.textContent = lines.join(NL); }
            }

            function show() {
                if (!build()) {
                    if (!pending) {
                        pending = true;
                        document.addEventListener('DOMContentLoaded', function () {
                            pending = false;
                            show();
                        });
                    }
                    return;
                }
                panel.style.display = 'block';
                render();
                panel.scrollTop = panel.scrollHeight;
            }

            function hide() {
                if (panel) { panel.style.display = 'none'; }
            }

            function log(tag, msg) {
                lines.push(stamp() + ' [' + tag + '] ' + fmt(msg));
                while (lines.length > MAX) { lines.shift(); }
                if (panel && panel.style.display === 'block') {
                    render();
                    panel.scrollTop = panel.scrollHeight;
                }
                if (tag === 'ERR') { show(); }
            }

            window.__stvDiag = { log: log, show: show, hide: hide };

            window.addEventListener('error', function (e) {
                log('ERR', 'onerror ' + (e.message || '') + ' @' + (e.filename || '') + ':' + (e.lineno || 0));
            }, true);
            window.addEventListener('unhandledrejection', function (e) {
                var r = e.reason;
                log('ERR', 'unhandledrejection ' + fmt((r && (r.stack || r.message)) || r));
            });

            var origError = console.error;
            var origWarn = console.warn;
            var origLog = console.log;
            function tee(orig, tag) {
                return function () {
                    var parts = [];
                    for (var i = 0; i < arguments.length; i++) { parts.push(fmt(arguments[i])); }
                    log(tag, parts.join(' '));
                    return orig.apply(console, arguments);
                };
            }
            console.error = tee(origError, 'ERR');
            console.warn = tee(origWarn, 'WARN');
            console.log = tee(origLog, 'LOG');

            var taps = 0;
            var last = 0;
            document.addEventListener('touchstart', function (e) {
                var t = e.touches && e.touches[0];
                if (!t) { return; }
                if (t.clientX < 70 && t.clientY < 70) {
                    var now = Date.now();
                    taps = (now - last < 700) ? taps + 1 : 1;
                    last = now;
                    if (taps >= 3) {
                        taps = 0;
                        if (panel && panel.style.display === 'block') { hide(); } else { show(); }
                    }
                }
            }, true);
        })();
        """

        let script = WKUserScript(source: source,
                                  injectionTime: .atDocumentStart,
                                  forMainFrameOnly: true)

        // The web view exists before plugins load (CAPBridgeViewController
        // .loadView() -> prepareWebView() -> CapacitorBridge.init() -> plugins)
        // and the page URL is loaded later in viewDidLoad(), so this lands in
        // time. Retry briefly anyway: a missed injection would be invisible.
        func attach(_ attemptsLeft: Int) {
            if let controller = self.bridge?.webView?.configuration.userContentController {
                controller.addUserScript(script)
                CAPLog.print("[SangTacApp] Cordova globals shim installed (nativeclick, TTS)")
            } else if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    attach(attemptsLeft - 1)
                }
            } else {
                CAPLog.print("[SangTacApp] WARNING: no webView, Cordova globals shim NOT installed")
            }
        }
        attach(20)
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Bridged methods

    /// iOS forbids programmatic termination, so acknowledge instead of crashing.
    @objc func exitApp(_ call: CAPPluginCall) {
        CAPLog.print("[SangTacApp] exitApp() requested; iOS cannot terminate programmatically, ignoring")
        call.resolve()
    }

    @objc func getInfo(_ call: CAPPluginCall) {
        guard let info = Bundle.main.infoDictionary else {
            call.reject("Unable to get App Info")
            return
        }
        call.resolve([
            "name": info["CFBundleDisplayName"] as? String ?? "",
            "id": info["CFBundleIdentifier"] as? String ?? "",
            "build": info["CFBundleVersion"] as? String ?? "",
            "version": info["CFBundleShortVersionString"] as? String ?? ""
        ])
    }

    @objc func getLaunchUrl(_ call: CAPPluginCall) {
        if let lastUrl = ApplicationDelegateProxy.shared.lastURL {
            call.resolve(["url": lastUrl.absoluteString])
        } else {
            call.resolve()
        }
    }

    @objc func getState(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            call.resolve(["isActive": UIApplication.shared.applicationState == .active])
        }
    }

    @objc func SyncCookie(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                CAPLog.print("[SangTacApp:SyncCookie] \(cookies.count) cookie(s) visible to native layer")
                call.resolve(["value": true, "count": cookies.count])
            }
        }
    }
}
