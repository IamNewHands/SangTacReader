import Foundation
import Capacitor
import WebKit

/**
 SangTacHttpPlugin — iOS stand-in for the Android build's
 `com.getcapacitor.plugin.http.Http` (which the APK patched to add X-STV-Sign).

 The site's frontend (app.v2.js / app.v2.bookdisplay.js) calls
 `Capacitor.Plugins.Http.get({url, headers, ...})` whenever `window.Capacitor`
 exists, with headers:
   x-stv-transport: app
   x-requested-with: com.sangtacviet.mobilereader
   Cookie: document.cookie        <- incomplete: httpOnly cookies are missing

 Two things this plugin must fix on iOS:
  1. httpOnly cookies (access / useri2 / hstamp ...) never appear in
     `document.cookie`, so the JS-supplied Cookie header is incomplete.
     We rebuild it from WKWebsiteDataStore (which does hold httpOnly cookies).
  2. WKWebView and URLSession do not share cookie storage, so Set-Cookie
     responses are written back into the web view's cookie store afterwards.

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
        CAPPluginMethod(name: "syncCookies", returnType: CAPPluginReturnPromise)
    ]

    private static let defaultUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        return URLSession(configuration: config)
    }()

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

    // MARK: - Core request path

    private func perform(_ method: String, _ call: CAPPluginCall) {
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

        // Implicit browser headers the site relies on (Referer is required by
        // the site's readchapter endpoint; URLSession does not add it itself).
        if headers["Referer"] == nil, let scheme = url.scheme, let host = url.host {
            headers["Referer"] = "\(scheme)://\(host)/"
        }
        if headers["User-Agent"] == nil, headers["user-agent"] == nil {
            headers["User-Agent"] = SangTacHttpPlugin.defaultUserAgent
        }

        let jsCookieHeader = headers.first { $0.key.lowercased() == "cookie" }?.value

        nativeCookies(for: url) { [weak self] cookies in
            guard let self = self else { return }

            if !cookies.isEmpty {
                headers["Cookie"] = SangTacHttpPlugin.mergeCookieHeader(
                    jsHeader: jsCookieHeader, nativeCookies: cookies)
            }

            // Build the body first: it may contribute a Content-Type header.
            let body = self.bodyData(for: call, headers: &headers)

            var request = URLRequest(url: url)
            request.httpMethod = method
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            if let body = body {
                request.httpBody = body
            }

            self.session.dataTask(with: request) { data, response, error in
                if let error = error {
                    self.callLog("err", "\(method) \(url.absoluteString) -> \(error.localizedDescription)")
                    call.reject(error.localizedDescription, nil, error)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    call.reject("No HTTP response")
                    return
                }

                self.storeResponseCookies(http, for: url)

                let body = data ?? Data()
                let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                let headerMap = http.allHeaderFields.reduce(into: [String: String]()) { acc, pair in
                    if let key = pair.key as? String { acc[key] = String(describing: pair.value) }
                }

                var result: [String: Any] = [
                    "status": http.statusCode,
                    "headers": headerMap,
                    "url": http.url?.absoluteString ?? url.absoluteString
                ]

                let text = String(data: body, encoding: .utf8) ?? ""
                if contentType.contains("json") || (text.hasPrefix("{") || text.hasPrefix("[")) {
                    if let parsed = try? JSONSerialization.jsonObject(with: body),
                       let json = parsed as? [String: Any] {
                        result["data"] = json
                    } else if let parsed = try? JSONSerialization.jsonObject(with: body),
                              let jsonArray = parsed as? [Any] {
                        result["data"] = jsonArray
                    } else {
                        result["data"] = text
                    }
                } else {
                    result["data"] = text
                }

                self.callLog("ok", "\(method) \(url.path) -> \(http.statusCode) bytes=\(body.count)")
                call.resolve(result)
            }.resume()
        }
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
