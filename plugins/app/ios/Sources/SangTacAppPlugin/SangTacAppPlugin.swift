import Foundation
import Capacitor
import Security
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

 This plugin is also where the site-patch JavaScript is injected (see
 SitePatch.swift) and where native text-to-speech lives (see NativeSpeech.swift).
 `speak` / `speakToFile` / `stopSpeech` / `getVoices` exist because the iOS build
 has to stand in for cordova-plugin-tts-advanced, which the Android APK ships.
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
        CAPPluginMethod(name: "SyncCookie", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "speak", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "speakToFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopSpeech", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getVoices", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getSafeArea", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "settingsSave", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "settingsRestore", returnType: CAPPluginReturnPromise)
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

        installDocumentStartScripts()
    }

    // MARK: - Site patches

    /**
     Every block in SitePatch is injected as its own WKUserScript at document
     start, so the globals exist before any page script runs. The page itself is
     loaded remotely (capacitor.config.json `server.url`), so these are the only
     hooks we have into the site.

     Why document start matters: the site references `nativeclick` unguarded on
     the book-list click path, so without it the very first line of the handler
     throws and the book never opens.
     */
    private func installDocumentStartScripts() {
        let scripts = SitePatch.all.map { source in
            WKUserScript(source: source,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: true)
        }

        // The web view exists before plugins load (CAPBridgeViewController
        // .loadView() -> prepareWebView() -> CapacitorBridge.init() -> plugins)
        // and the page URL is loaded later in viewDidLoad(), so this lands in
        // time. Retry briefly anyway: a missed injection would be invisible.
        func attach(_ attemptsLeft: Int) {
            if let controller = self.bridge?.webView?.configuration.userContentController {
                for script in scripts {
                    controller.addUserScript(script)
                }
                CAPLog.print("[SangTacApp] site patches installed (\(scripts.count) scripts)")
            } else if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    attach(attemptsLeft - 1)
                }
            } else {
                CAPLog.print("[SangTacApp] WARNING: no webView, site patches NOT installed")
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

    // MARK: - Text to speech

    /**
     Cordova's `TTS.speak(options)` plays immediately; `TTS.speakToFile(options)`
     returns the audio bytes. The site's iOS path only ever needs speakToFile —
     it hands the bytes to ttsEngine, which decodes them and plays through its
     own WebAudio graph so the equaliser and per-sentence pacing keep working.
     */
    @objc func speak(_ call: CAPPluginCall) {
        guard let text = call.getString("text"), !text.isEmpty else {
            call.reject("Missing 'text'")
            return
        }
        NativeSpeech.shared.speakDirectly(text: text,
                                          identifier: call.getString("identifier"),
                                          rate: SangTacAppPlugin.numberOption(call, "rate", fallback: 1),
                                          pitch: SangTacAppPlugin.numberOption(call, "pitch", fallback: 1))
        call.resolve(["value": true])
    }

    @objc func speakToFile(_ call: CAPPluginCall) {
        guard let text = call.getString("text"), !text.isEmpty else {
            call.reject("Missing 'text'")
            return
        }
        let identifier = call.getString("identifier")
        let rate = SangTacAppPlugin.numberOption(call, "rate", fallback: 1)
        let pitch = SangTacAppPlugin.numberOption(call, "pitch", fallback: 1)
        report("TTS", "speakToFile \(text.count) chars voice=\(identifier ?? "default")")

        // Every synthesis attempt is mirrored into the in-page panel: the site's
        // own failure message ("Không tìm thấy blob") says nothing about WHY the
        // audio was empty, and a sideloaded build has no readable console.
        NativeSpeech.shared.synthesize(text: text,
                                       identifier: identifier,
                                       rate: rate,
                                       pitch: pitch,
                                       trace: { [weak self] message in
            CAPLog.print("[SangTacApp:tts] \(message)")
            self?.report("TTS", message)
        }) { [weak self] result in
            switch result {
            case .success(let data):
                CAPLog.print("[SangTacApp:tts] synthesised \(data.count) bytes")
                self?.report("TTS", "synthesised \(data.count) bytes")
                call.resolve(["data": data.base64EncodedString(), "mime": "audio/wav"])
            case .failure(let error):
                CAPLog.print("[SangTacApp:tts] failed: \(error.localizedDescription)")
                self?.report("ERR", "TTS failed: \(error.localizedDescription)")
                call.reject(error.localizedDescription)
            }
        }
    }

    @objc func stopSpeech(_ call: CAPPluginCall) {
        NativeSpeech.shared.stopAll()
        call.resolve(["value": true])
    }

    @objc func getVoices(_ call: CAPPluginCall) {
        let voices = NativeSpeech.shared.availableVoices().map { voice -> [String: Any] in
            return [
                "identifier": voice.identifier,
                "name": voice.name,
                "language": voice.language,
                "gender": voice.gender
            ]
        }
        CAPLog.print("[SangTacApp:tts] \(voices.count) Vietnamese voice(s)")
        call.resolve(["voices": voices])
    }

    /// Read the raw bridged value rather than a typed accessor, so a non-numeric
    /// option can never trap (same reasoning as SangTacHttpPlugin.timeoutSeconds).
    private static func numberOption(_ call: CAPPluginCall, _ key: String, fallback: Double) -> Double {
        guard let raw = call.options[key], !(raw is NSNull) else { return fallback }
        if let number = raw as? NSNumber { return number.doubleValue }
        if let text = raw as? String, let parsed = Double(text) { return parsed }
        return fallback
    }

    // MARK: - Safe area

    /**
     The site derives its own safe-area variables from `env(safe-area-inset-*)`,
     but only inside `window.onresize`, which `overlayStatusBar(true)` schedules.
     Hand the real insets to the `safeArea` site patch so it can fill in whatever
     the site leaves at 0 -- without them the reader's overlay title bar sits
     under the Dynamic Island and its buttons cannot be tapped.
     */
    @objc func getSafeArea(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            var insets = UIEdgeInsets.zero
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
                ?? scenes.first?.windows.first
            if let window = window {
                insets = window.safeAreaInsets
            }
            call.resolve([
                "top": Double(insets.top),
                "bottom": Double(insets.bottom),
                "left": Double(insets.left),
                "right": Double(insets.right)
            ])
        }
    }

    // MARK: - Settings backup

    /**
     The site stores its configuration in localStorage, which lives in the app's
     data container and is therefore erased by every reinstall of a sideloaded
     IPA. Keychain items are not removed when an app is deleted, so they are the
     only device-local store that survives; the `settingsBackup` site patch
     mirrors `config.reader` / `config.ux` / `config.comicReader` / `tts.setting`
     here and writes them back before the site reads its config.
     */
    private static let settingsService = "com.sangtacviet.mobilereader.settings"

    @objc func settingsSave(_ call: CAPPluginCall) {
        guard let key = call.getString("key"), !key.isEmpty,
              let value = call.getString("value") else {
            call.reject("Missing 'key' or 'value'")
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SangTacAppPlugin.settingsService,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status == errSecSuccess {
            call.resolve(["value": true, "bytes": value.count])
        } else {
            // Sideloaded builds can lack the keychain entitlement; the patch
            // treats this as "no backup" rather than breaking the setting.
            CAPLog.print("[SangTacApp:settings] keychain write failed for \(key): \(status)")
            call.reject("keychain write failed (\(status))")
        }
    }

    /**
     Returns every backed-up key. The patch filters by key on the JS side so a
     dynamic key (`reader.style.<name>`) needs no bookkeeping here.
     */
    @objc func settingsRestore(_ call: CAPPluginCall) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SangTacAppPlugin.settingsService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        guard status == errSecSuccess, let list = items as? [[String: Any]] else {
            CAPLog.print("[SangTacApp:settings] no keychain backup yet (status \(status))")
            call.resolve(["entries": [:]])
            return
        }
        var entries: [String: String] = [:]
        for item in list {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data,
                  let text = String(data: data, encoding: .utf8) else { continue }
            entries[account] = text
        }
        CAPLog.print("[SangTacApp:settings] \(entries.count) key(s) found in keychain")
        call.resolve(["entries": entries])
    }

    // MARK: - Diagnostics

    /// Push one line into the in-page diagnostic panel installed by the `diag`
    /// site patch (window.__stvDiag). Silent when the panel is absent.
    private func report(_ tag: String, _ message: String) {
        let js = "window.__stvDiag && window.__stvDiag.log(\(SangTacAppPlugin.jsLiteral(tag)), "
            + "\(SangTacAppPlugin.jsLiteral(message)));"
        DispatchQueue.main.async { [weak self] in
            self?.bridge?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private static func jsLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return String(array.dropFirst().dropLast())
    }
}
