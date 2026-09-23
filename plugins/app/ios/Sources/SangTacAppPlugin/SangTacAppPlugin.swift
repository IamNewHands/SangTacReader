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
        CAPPluginMethod(name: "settingsRestore", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "secretSave", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "secretLoad", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "translationStatus", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "translationPrepare", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "translationTranslate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "exportFile", returnType: CAPPluginReturnPromise)
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
     Host check for the methods below that touch the keychain.

     What it does: refuses the call unless the web view's *main frame* is on one
     of the site's own domains. That closes the real case where the top frame is
     navigated somewhere else and the bridge comes with it -- `challenges.cloudflare.com`
     is in `allowNavigation` precisely because the login challenge may become the
     top frame, so this is a state the app can actually be in, not a hypothetical.

     What it does NOT do, and must not be described as doing: stop a script that
     already runs inside the site's own page. Capacitor's script-message handler
     does not check `frameInfo.isMainFrame`
     (node_modules/@capacitor/ios/.../WebViewDelegationHandler.swift:192), and
     `bridge.webView.url` reports the main frame, so a hostile iframe -- or
     main-frame XSS, or a compromised third-party script -- still reports
     `sangtacviet.com` and passes this check. The boundary that actually holds for
     those callers is the key allow-list in `settingsSave` plus the fact that
     `secretLoad` only ever returns the single named secret. This limitation is
     inherent to injecting into the page at all (the optimization plan's S6 says
     the same thing); it is not something this method can fix from inside a plugin.

     `speakToFile` and the translation bridge are deliberately not gated: they
     reach the speech synthesizer and the system translation sheet, not stored
     state.

     `trustedHosts` is kept a deliberate *superset* of
     `capacitor.config.json`'s `allowNavigation`, so adding a domain there later
     cannot silently start refusing the keychain to a page that is legitimately
     the top frame.
     */
    private static let trustedHosts = [
        "sangtacviet.com",
        "sangtacviet.vip",
        "sangtacviet.app"
    ]

    private func isTrustedCaller(_ method: String) -> Bool {
        guard let host = bridge?.webView?.url?.host?.lowercased(), !host.isEmpty else {
            CAPLog.print("[SangTacApp:\(method)] refused: no web view origin")
            return false
        }
        let allowed = SangTacAppPlugin.trustedHosts.contains {
            host == $0 || host.hasSuffix("." + $0)
        }
        if !allowed {
            CAPLog.print("[SangTacApp:\(method)] refused for origin \(host)")
        }
        return allowed
    }

    /**
     The site stores its configuration in localStorage, which lives in the app's
     data container and is therefore erased by every reinstall of a sideloaded
     IPA. Keychain items are not removed when an app is deleted, so they are the
     only device-local store that survives; the `settingsBackup` site patch
     mirrors `config.reader` / `config.ux` / `config.comicReader` / `tts.setting`
     here and writes them back before the site reads its config.
     */
    private static let settingsService = "com.sangtacviet.mobilereader.settings"

    /// Keys the `settingsBackup` patch is allowed to mirror. Kept in sync with
    /// that block's KEYS / PREFIXES lists: an open key namespace would let any
    /// script on the page fill the keychain with arbitrary entries.
    private static let settingKeys: Set<String> = [
        "config.reader", "config.ux", "config.comicReader", "tts.setting",
        "readthemeset", "offlineBook", "stv.translate.settings", "stv.diag.settings"
    ]
    private static let settingKeyPrefixes = ["reader.style."]
    private static let maxSettingKeyLength = 64
    private static let maxSettingValueBytes = 512 * 1024

    private static func isAllowedSettingKey(_ key: String) -> Bool {
        if settingKeys.contains(key) { return true }
        if key.count > maxSettingKeyLength { return false }
        return settingKeyPrefixes.contains { key.hasPrefix($0) }
    }

    @objc func settingsSave(_ call: CAPPluginCall) {
        guard isTrustedCaller("settingsSave") else {
            call.reject("settingsSave is not available from this origin")
            return
        }
        guard let key = call.getString("key"), !key.isEmpty,
              let value = call.getString("value") else {
            call.reject("Missing 'key' or 'value'")
            return
        }
        guard SangTacAppPlugin.isAllowedSettingKey(key) else {
            CAPLog.print("[SangTacApp:settings] rejected key \(key)")
            call.reject("key not backed up by this app")
            return
        }
        guard value.utf8.count <= SangTacAppPlugin.maxSettingValueBytes else {
            call.reject("value too large for the settings backup")
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
        guard isTrustedCaller("settingsRestore") else {
            call.reject("settingsRestore is not available from this origin")
            return
        }
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

    // MARK: - Secret store (API keys)

    /**
     A second keychain namespace for credentials, separate from the settings
     mirror for three reasons:

       * The settings mirror is deliberately readable after a reinstall, which is
         exactly what a credential must not be. This service uses
         `AfterFirstUnlockThisDeviceOnly`, so the item is excluded from iCloud and
         iTunes backups and never migrates to another device.
       * The translate settings record is mirrored wholesale into that backup, so
         a key stored inside it would ride along. The record now keeps only
         `hasApiKey`; the value lives here and is fetched on demand.
       * Keeping it out of `settingsRestore` means the bulk restore can never
         replay a stale credential over a newer one.
     */
    private static let secretService = "com.sangtacviet.mobilereader.secrets"
    private static let maxSecretKeyLength = 64
    private static let maxSecretValueBytes = 8 * 1024

    private static func secretQuery(key: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: secretService,
            kSecAttrAccount as String: key
        ]
    }

    /// `value: ""` clears the item, so the JS side needs no third method. A
    /// *missing* `value` is rejected rather than treated as empty: otherwise a
    /// malformed `secretSave({key})` would silently delete the stored key.
    @objc func secretSave(_ call: CAPPluginCall) {
        guard isTrustedCaller("secretSave") else {
            call.reject("secretSave is not available from this origin")
            return
        }
        guard let key = call.getString("key"), !key.isEmpty,
              key.count <= SangTacAppPlugin.maxSecretKeyLength else {
            call.reject("Missing or oversized 'key'")
            return
        }
        guard let value = call.getString("value") else {
            call.reject("Missing 'value'")
            return
        }
        guard value.utf8.count <= SangTacAppPlugin.maxSecretValueBytes else {
            call.reject("secret too large")
            return
        }
        let query = SangTacAppPlugin.secretQuery(key: key)
        SecItemDelete(query as CFDictionary)
        if value.isEmpty {
            call.resolve(["value": true, "stored": false])
            return
        }
        var insert = query
        insert[kSecValueData as String] = Data(value.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status == errSecSuccess {
            call.resolve(["value": true, "stored": true, "bytes": value.count])
        } else {
            CAPLog.print("[SangTacApp:secret] keychain write failed for \(key): \(status)")
            call.reject("keychain write failed (\(status))")
        }
    }

    /// Returns `{value: ""}` when nothing is stored; the caller treats an empty
    /// value as "no key configured" rather than as an error.
    @objc func secretLoad(_ call: CAPPluginCall) {
        guard isTrustedCaller("secretLoad") else {
            call.reject("secretLoad is not available from this origin")
            return
        }
        guard let key = call.getString("key"), !key.isEmpty,
              key.count <= SangTacAppPlugin.maxSecretKeyLength else {
            call.reject("Missing or oversized 'key'")
            return
        }
        var query = SangTacAppPlugin.secretQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            call.resolve(["value": ""])
            return
        }
        guard status == errSecSuccess, let data = item as? Data else {
            CAPLog.print("[SangTacApp:secret] keychain read failed for \(key): \(status)")
            call.reject("keychain read failed (\(status))")
            return
        }
        call.resolve(["value": String(data: data, encoding: .utf8) ?? ""])
    }

    // MARK: - Offline translation (iOS 18+)

    /**
     The comment page's translate buttons. Declared on every iOS version on
     purpose: the JS layer probes for the selectors, and a selector that simply
     did not exist on iOS 15-17 would surface as an opaque bridge error instead
     of the definite "unsupported" answer it can act on. See TranslationBridge.
     */
    @objc func translationStatus(_ call: CAPPluginCall) {
        TranslationSupport.handle("status", call, parent: bridge?.viewController)
    }

    @objc func translationPrepare(_ call: CAPPluginCall) {
        TranslationSupport.handle("prepare", call, parent: bridge?.viewController)
    }

    @objc func translationTranslate(_ call: CAPPluginCall) {
        TranslationSupport.handle("translate", call, parent: bridge?.viewController)
    }

    // MARK: - File export

    /**
     The downloaded list's 导出 button builds a TXT or an EPUB in the page (see
     the `downloadExport` site patch) and hands the finished bytes here, because
     a WKWebView has no other way to produce a file the reader can reach:
     `<a download>` is ignored, and this build ships no Filesystem plugin.

     The bytes go into the app's temporary directory and then straight into the
     system share sheet, which is the only surface iOS offers for "here is a
     document the reader asked for" -- 存储到"文件", AirDrop, or another reader.
     The temporary directory is the right home: the copy only has to outlive the
     sheet or the receiving app, and iOS reclaims it without this plugin having
     to track anything.

     Deliberately NOT behind isTrustedCaller, unlike the keychain methods. It
     reads no stored state and returns no data to the caller: it writes bytes the
     caller supplied into a file whose name the caller supplied, and raises UI.
     `speakToFile` and the translation bridge are ungated for the same reason,
     and gating this one would mean an export silently failing on a mirror
     domain that is not in `trustedHosts` -- a bug report this codebase can do
     without.
     */
    private static let maxExportBytes = 64 * 1024 * 1024
    private static let maxExportNameLength = 120

    /// The book title becomes the file name, so it can hold a path separator or
    /// a character iOS rejects. Keep the leaf name, then neutralise the rest.
    private static func safeFileName(_ raw: String) -> String {
        let leaf = (raw as NSString).lastPathComponent
        var cleaned = leaf.replacingOccurrences(of: "/", with: "_")
        cleaned = cleaned.replacingOccurrences(of: ":", with: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "export" }
        return String(trimmed.prefix(maxExportNameLength))
    }

    @objc func exportFile(_ call: CAPPluginCall) {
        guard let rawName = call.getString("filename"), !rawName.isEmpty else {
            call.reject("Missing 'filename'")
            return
        }
        guard let encoded = call.getString("data"), !encoded.isEmpty else {
            call.reject("Missing 'data'")
            return
        }
        // Checked before decoding: base64 of a 64MB archive is ~85MB of string,
        // and Data(base64Encoded:) would allocate it a second time.
        let ceiling = (SangTacAppPlugin.maxExportBytes / 3 + 1) * 4 + 8
        guard encoded.utf8.count <= ceiling else {
            call.reject("export is too large for this bridge")
            return
        }
        guard let payload = Data(base64Encoded: encoded,
                                 options: .ignoreUnknownCharacters) else {
            call.reject("'data' is not valid base64")
            return
        }
        guard payload.count <= SangTacAppPlugin.maxExportBytes else {
            call.reject("export is too large for this bridge")
            return
        }
        let name = SangTacAppPlugin.safeFileName(rawName)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try payload.write(to: url, options: .atomic)
        } catch {
            CAPLog.print("[SangTacApp:export] write failed for \(name): \(error)")
            call.reject("could not write \(name): \(error.localizedDescription)")
            return
        }
        CAPLog.print("[SangTacApp:export] wrote \(payload.count) byte(s) to \(name)")
        report("EXPORT", "wrote \(payload.count) byte(s) to \(name)")

        DispatchQueue.main.async { [weak self] in
            guard let host = self?.bridge?.viewController else {
                call.reject("no view controller to present the share sheet")
                return
            }
            let sheet = UIActivityViewController(activityItems: [url],
                                                 applicationActivities: nil)
            // Regular-width presentation (iPad, or any future split view) needs
            // an anchor or UIKit raises instead of degrading.
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = host.view
                popover.sourceRect = CGRect(x: host.view.bounds.midX,
                                            y: host.view.bounds.midY,
                                            width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            host.present(sheet, animated: true) {
                call.resolve(["value": true, "name": name, "bytes": payload.count])
            }
        }
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
