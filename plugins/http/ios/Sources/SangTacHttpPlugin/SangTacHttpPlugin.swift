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
public class SangTacHttpPlugin: CAPPlugin, CAPBridgedPlugin {

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
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                   diskCapacity: 256 * 1024 * 1024,
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

    // MARK: - Bridged methods

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
            call.reject("Invalid URL: \(urlString)")
            return
        }

        var headers: [String: String] = [:]
        if let raw = call.getObject("headers") {
            for (key, value) in raw where !(value is NSNull) {
                headers[key] = String(describing: value)
            }
        }

        let timeout = SangTacHttpPlugin.timeoutSeconds(from: call)
        let jsCookieHeader = headers.first { $0.key.lowercased() == "cookie" }?.value
        // Resolve the Referer fallback here, on the calling (main) thread, so we
        // never touch bridge.webView from a cookie-store callback queue.
        let refererFallback = pageReferer(for: url)

        nativeCookies(for: url) { [weak self] cookies in
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
                    let message = error.localizedDescription
                    self.callLog("err", "\(method) \(url.absoluteString) -> \(message)")
                    self.report("ERR", "\(method) \(url.absoluteString) FAILED in "
                        + "\(elapsedMs())ms: \(message)")
                    call.reject(message, nil, error)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self.report("ERR", "\(method) \(url.absoluteString) no HTTP response")
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

                self.callLog("ok", "\(method) \(url.absoluteString) -> \(http.statusCode) bytes=\(body.count) data=\(payload.kind)")
                // A 5xx is what we are usually hunting (the home "关注" tab was
                // reported blank); tag it ERR so it also flips the panel badge
                // red, and always carry a body preview so the server's own error
                // text is readable on device.
                let tag = http.statusCode >= 500 ? "ERR" : "Http"
                self.report(tag, "\(method) \(url.absoluteString) -> \(http.statusCode) "
                    + "\(contentType.isEmpty ? "no-content-type" : contentType) "
                    + "\(payload.kind) \(body.count)b in \(elapsedMs())ms "
                    + SangTacHttpPlugin.preview(payload: payload, body: body))
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
        let text = String(data: body, encoding: .utf8) ?? ""
        let isJSONMime = contentType.contains("application/json")
            || contentType.contains("application/vnd.api+json")

        if isJSONMime {
            if let parsed = parseJSON(body) { return Payload(value: parsed, kind: "json") }
            return Payload(value: text, kind: "string(unparsed-json)")
        }

        switch (responseType ?? "text").lowercased() {
        case "arraybuffer", "blob":
            return Payload(value: body.base64EncodedString(), kind: "base64")
        case "json":
            if let parsed = parseJSON(body) { return Payload(value: parsed, kind: "json") }
            return Payload(value: text, kind: "string(unparsed-json)")
        default:
            return Payload(value: text, kind: "string")
        }
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

    /// Push one line into the in-page diagnostic panel installed by
    /// SangTacAppPlugin (window.__stvDiag). Silent when the panel is absent.
    private func report(_ tag: String, _ message: String) {
        let js = "window.__stvDiag && window.__stvDiag.log(\(SangTacHttpPlugin.jsLiteral(tag)), \(SangTacHttpPlugin.jsLiteral(message)));"
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

    /// One line of the response body, so a server-side error message is readable
    /// in the on-device panel instead of just "status 500".
    private static func preview(payload: Payload, body: Data) -> String {
        let text: String
        if let string = payload.value as? String {
            text = string
        } else {
            text = String(data: body, encoding: .utf8) ?? ""
        }
        let collapsed = text
            .split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .joined(separator: " ")
        if collapsed.count <= 240 { return collapsed }
        return String(collapsed.prefix(240)) + "..."
    }

    // MARK: - Cookies

    private func nativeCookies(for url: URL?, _ completion: @escaping ([HTTPCookie]) -> Void) {
        DispatchQueue.main.async {
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                guard let url = url else {
                    completion(cookies)
                    return
                }
                let host = url.host ?? ""
                let matching = cookies.filter { cookie in
                    let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                    return host == domain || host.hasSuffix("." + domain)
                }
                completion(matching)
            }
        }
    }

    private func storeResponseCookies(_ response: HTTPURLResponse, for url: URL) {
        let headerFields = response.allHeaderFields.reduce(into: [String: String]()) { acc, pair in
            if let key = pair.key as? String { acc[key] = String(describing: pair.value) }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        guard !cookies.isEmpty else { return }
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
        CAPLog.print("[SangTacHttp:\(tag)] \(message)")
    }
}
