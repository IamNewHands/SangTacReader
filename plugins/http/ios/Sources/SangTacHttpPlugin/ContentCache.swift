import Foundation
import Capacitor
import CryptoKit

/**
 The persistent half of the Http plugin: answers the site has already given us,
 kept across launches.

 Why this exists (docs/capacitor-port.md §6.45): the plugin used to keep only a
 session-scoped, in-memory dictionary, and only for two endpoint families. Every
 cold start therefore re-fetched the chapter list (115KB, three times in one
 launch in the 2026-09-23 log), every chapter the reader had already read, the
 book detail page, and every cover -- over a link whose first byte takes
 500-960ms. Nothing about that content changes between two launches of the same
 day, and most of it does not change for weeks.

 The shape of the answer is a small JSON sidecar per entry plus the raw response
 bytes:

     Library/Application Support/stv-content-cache/
         <sha256(key)>.meta     <- commits the entry; JSON, written last
         <sha256(key)>.body     <- the bytes, exactly as the network returned them

 Application Support, not Caches: iOS evicts Caches under storage pressure, and
 an evicted content cache is silently the old slow behaviour again. The budget in
 `ContentCacheConfig` is what bounds the footprint instead.

 Everything here is deliberately conservative in one direction: an answer that
 cannot be recognised is not stored, and an entry that cannot be read is dropped
 rather than served. The cost of being wrong that way is one more round trip; the
 cost of being wrong the other way is a reader staring at a paywall page that the
 cache insists is chapter 641.
 */
enum ContentClass: String, CaseIterable {
    /// `/?sajax=readchapter&h&bookid&c&key` -- the chapter text itself.
    case chapter
    /// `/index.php?ngmar=chapterlist&h&bookid&sajax=getchapterlist`.
    case chapterList
    /// `/mobile/bookinfo.php?hid&host` -- the detail page's own data.
    case bookInfo
    /// Covers and page images, fetched through `Http.get({responseType: blob})`.
    case image
    /// `POST /mobile/booklist.php?method=history|following|bookmarked|mybook|…`.
    case homeList
    /// `/mobile/userinfo.php` -- unread counts and the profile row.
    case userInfo
    /// `/mobile/comment.php?act=readcomment…&start=0` -- the first comment page.
    case comment
    /// `/io/grantcontext/context?hostid&bookid` -- 844KB, and the source of the
    /// short-lived `key=` the chapter URLs carry (`app.v2.read.js:535-551`).
    case grant
}

/// What a stored answer is worth, per class.
struct ContentPolicy {
    let cls: ContentClass
    /// How long a stored answer counts as fresh. Always set: an answer with no
    /// clock at all would only ever be evicted by the byte budget, and the
    /// content behind these URLs is not immutable enough to claim that.
    let ttl: TimeInterval
    /// Serve a stale answer immediately and refresh behind the reader instead of
    /// making them wait for the network (user requirement: "先显示，后台再刷新").
    let serveStale: Bool
    /// Whether a refresh asks the server "is this still current?" (304) instead
    /// of re-downloading the body.
    let revalidate: Bool
    /// The gate a response body has to pass before it is stored.
    let accepts: (Data, String) -> Bool
}

struct ContentCacheConfig {
    var enabled = true
    var maxBytes = 256 * 1024 * 1024
    var maxEntries = 4000
    /// Longest a time-limited answer may be kept, in days. This is the
    /// "保留时间" row in the settings page; it caps the per-class TTL rather than
    /// scaling it, so choosing 7 days cannot shorten the 60-second userinfo
    /// window or the 10-minute list window into nonsense.
    var retentionDays = 30

    static let retentionChoices = [7, 30, 90, 365]
    static let byteChoices = [128, 256, 512, 1024]

    private static let defaultsKey = "stv.contentcache.config"

    static func load() -> ContentCacheConfig {
        var config = ContentCacheConfig()
        if let raw = UserDefaults.standard.dictionary(forKey: defaultsKey) {
            // NSNumber, not `as? Bool`: UserDefaults hands back CFBoolean-backed
            // numbers, and the plugin's own `setDiagnostics` reads them the same
            // way for the same reason.
            if let enabled = raw["enabled"] as? NSNumber { config.enabled = enabled.boolValue }
            if let bytes = raw["maxBytes"] as? NSNumber, bytes.intValue > 0 {
                config.maxBytes = bytes.intValue
            }
            if let entries = raw["maxEntries"] as? NSNumber, entries.intValue > 0 {
                config.maxEntries = entries.intValue
            }
            if let days = raw["retentionDays"] as? NSNumber, days.intValue > 0 {
                config.retentionDays = days.intValue
            }
        }
        return config
    }

    func save() {
        UserDefaults.standard.set([
            "enabled": enabled,
            "maxBytes": maxBytes,
            "maxEntries": maxEntries,
            "retentionDays": retentionDays
        ], forKey: ContentCacheConfig.defaultsKey)
    }
}

enum ContentPolicies {

    static let day: TimeInterval = 24 * 60 * 60

    static func policy(for cls: ContentClass, config: ContentCacheConfig) -> ContentPolicy {
        let cap = TimeInterval(config.retentionDays) * day
        switch cls {
        case .chapter:
            // Published prose. The one thing that would change it is an author
            // edit, and the reader is better served by the text they already had
            // than by a spinner.
            return ContentPolicy(cls: cls, ttl: min(30 * day, cap),
                                 serveStale: true, revalidate: true,
                                 accepts: ContentCache.isChapterBody)
        case .chapterList:
            // ~115KB the device log shows fetched three times in one launch.
            // Changes only when the author publishes.
            return ContentPolicy(cls: cls, ttl: min(6 * 3600, cap),
                                 serveStale: true, revalidate: true,
                                 accepts: ContentCache.isChapterListBody)
        case .bookInfo:
            return ContentPolicy(cls: cls, ttl: min(day, cap),
                                 serveStale: true, revalidate: true,
                                 accepts: ContentCache.isJSONBody)
        case .image:
            return ContentPolicy(cls: cls, ttl: min(30 * day, cap),
                                 serveStale: false, revalidate: false,
                                 accepts: ContentCache.isImageBody)
        case .homeList:
            // Unread counts and "last updated" move in minutes. Ten minutes of
            // staleness is invisible next to a 1-4s wait on every cold start.
            return ContentPolicy(cls: cls, ttl: min(600, cap),
                                 serveStale: true, revalidate: false,
                                 accepts: ContentCache.isJSONBody)
        case .userInfo:
            // The one class where a stale answer is visible as a wrong number,
            // so it is only reused inside a minute-wide window.
            return ContentPolicy(cls: cls, ttl: min(60, cap),
                                 serveStale: false, revalidate: false,
                                 accepts: ContentCache.isJSONBody)
        case .comment:
            return ContentPolicy(cls: cls, ttl: min(300, cap),
                                 serveStale: false, revalidate: false,
                                 accepts: ContentCache.isJSONBody)
        case .grant:
            // The token inside may be single-use or time-limited (unproven), so
            // this stays short: it only pays off when the reader kills and
            // reopens the app within the same quarter hour.
            return ContentPolicy(cls: cls, ttl: min(900, cap),
                                 serveStale: false, revalidate: false,
                                 accepts: ContentCache.isJSONBody)
        }
    }
}

final class ContentCache {

    struct Entry {
        let key: String
        let cls: ContentClass
        let status: Int
        let contentType: String
        let headers: [String: String]
        let storedAt: Date
        let expiresAt: Date?
        let bytes: Int
        let servedBy: String
        let bodyFile: URL
        var lastAccess: Date
        var accessDirty: Bool
    }

    private struct Meta: Codable {
        var version = 1
        var key = ""
        var cls = ""
        var status = 0
        var contentType = ""
        var headers: [String: String] = [:]
        var storedAt = 0.0
        var expiresAt = 0.0
        var lastAccess = 0.0
        var bytes = 0
        var servedBy = ""
    }

    /// A single answer that must never take a whole device's storage with it.
    private static let maxEntryBytes = 32 * 1024 * 1024

    private let lock = NSLock()
    private var index: [String: Entry] = [:]
    private var byteCount = 0
    private var ready = false
    private var lastAccessFlush = Date.distantPast

    private var hits = 0
    private var staleServed = 0
    private var misses = 0
    private var stores = 0
    private var rejects = 0
    private var evictions = 0
    private var revalidations = 0
    private var refreshedChanges = 0

    private(set) var config: ContentCacheConfig

    let root: URL?

    init(root: URL? = ContentCache.defaultRoot(), config: ContentCacheConfig = .load()) {
        self.root = root
        self.config = config
        guard let root = root else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.loadIndex(root: root)
        }
    }

    static func defaultRoot() -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("stv-content-cache", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return dir
    }

    // MARK: - Index

    private func loadIndex(root: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        var loaded: [String: Entry] = [:]
        var bytes = 0
        let decoder = JSONDecoder()
        for meta in files where meta.pathExtension == "meta" {
            guard let data = try? Data(contentsOf: meta),
                  let record = try? decoder.decode(Meta.self, from: data),
                  !record.key.isEmpty,
                  let cls = ContentClass(rawValue: record.cls) else { continue }
            let body = meta.deletingPathExtension().appendingPathExtension("body")
            guard FileManager.default.fileExists(atPath: body.path) else {
                // A meta without its body is a half-written entry (the body is
                // written first, so this can only happen after a crash between
                // the two writes). Drop it rather than keep a promise we cannot
                // keep.
                try? FileManager.default.removeItem(at: meta)
                continue
            }
            loaded[record.key] = Entry(
                key: record.key,
                cls: cls,
                status: record.status,
                contentType: record.contentType,
                headers: record.headers,
                storedAt: Date(timeIntervalSince1970: record.storedAt),
                expiresAt: record.expiresAt > 0 ? Date(timeIntervalSince1970: record.expiresAt) : nil,
                bytes: record.bytes,
                servedBy: record.servedBy,
                bodyFile: body,
                lastAccess: Date(timeIntervalSince1970: record.lastAccess),
                accessDirty: false)
            bytes += record.bytes
        }
        lock.lock()
        index = loaded
        byteCount = bytes
        ready = true
        lock.unlock()
    }

    // MARK: - Reading

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return config.enabled && root != nil
    }

    /// Fresh or stale is the caller's decision: `lookup` hands back what is on
    /// disk plus the entry, and the plugin compares `expiresAt` against now.
    func lookup(_ key: String) -> (entry: Entry, body: Data)? {
        lock.lock()
        guard config.enabled, var entry = index[key] else {
            if ready { misses += 1 }
            lock.unlock()
            return nil
        }
        entry.lastAccess = Date()
        entry.accessDirty = true
        index[key] = entry
        lock.unlock()

        guard let body = try? Data(contentsOf: entry.bodyFile), !body.isEmpty else {
            // The body vanished under us (storage pressure, a bad write). Forget
            // the entry; the next request goes to the network.
            forget(key)
            noteMiss()
            return nil
        }
        return (entry, body)
    }

    func noteMiss() {
        lock.lock()
        misses += 1
        lock.unlock()
    }

    func entry(_ key: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return index[key]
    }

    func noteHit() {
        lock.lock()
        hits += 1
        lock.unlock()
    }

    func noteStaleServed() {
        lock.lock()
        staleServed += 1
        lock.unlock()
    }

    func noteRevalidation(used304: Bool) {
        lock.lock()
        revalidations += 1
        if !used304 { refreshedChanges += 1 }
        lock.unlock()
    }

    func noteReject() {
        lock.lock()
        rejects += 1
        lock.unlock()
    }

    /// A 304, or a refresh whose bytes matched: keep the answer, restart its
    /// clock. This is the cheap half of revalidation -- the 115KB chapter list
    /// costs one round trip with no body.
    func renew(_ key: String, ttl: TimeInterval) {
        lock.lock()
        guard var entry = index[key] else {
            lock.unlock()
            return
        }
        entry = Entry(key: entry.key, cls: entry.cls, status: entry.status,
                      contentType: entry.contentType, headers: entry.headers,
                      storedAt: Date(), expiresAt: Date().addingTimeInterval(ttl),
                      bytes: entry.bytes, servedBy: entry.servedBy,
                      bodyFile: entry.bodyFile, lastAccess: Date(), accessDirty: true)
        index[key] = entry
        lock.unlock()
        writeMeta(entry)
    }

    // MARK: - Writing

    @discardableResult
    func store(key: String, cls: ContentClass, status: Int, contentType: String,
               headers: [String: String], body: Data, ttl: TimeInterval,
               servedBy: String) -> Bool {
        guard let root = root, config.enabled else { return false }
        guard !body.isEmpty, body.count <= ContentCache.maxEntryBytes else { return false }

        let file = root.appendingPathComponent(ContentCache.hashHex(key))
        let bodyFile = file.appendingPathExtension("body")

        let now = Date()
        var filtered: [String: String] = [:]
        for (name, value) in headers {
            // Only what a served-from-cache answer has to hand back. Set-Cookie
            // is deliberately absent: the cookies were stored when the response
            // was first received, and re-announcing them from a cache would be a
            // second, later write of the same state.
            switch name.lowercased() {
            case "content-type", "last-modified", "etag":
                filtered[name] = value
            default:
                break
            }
        }
        let entry = Entry(key: key, cls: cls, status: status, contentType: contentType,
                          headers: filtered, storedAt: now,
                          expiresAt: now.addingTimeInterval(ttl), bytes: body.count,
                          servedBy: servedBy, bodyFile: bodyFile,
                          lastAccess: now, accessDirty: false)
        do {
            try body.write(to: bodyFile, options: .atomic)
        } catch {
            return false
        }
        guard writeMeta(entry) else {
            try? FileManager.default.removeItem(at: bodyFile)
            return false
        }

        lock.lock()
        // Replacing an entry has to give its old bytes back to the budget first,
        // or a re-read chapter would count twice and evict a neighbour.
        if let old = index[key] { byteCount -= old.bytes }
        index[key] = entry
        byteCount += body.count
        stores += 1
        lock.unlock()
        evictIfNeeded()
        return true
    }

    private func writeMeta(_ entry: Entry) -> Bool {
        let metaFile = entry.bodyFile.deletingPathExtension().appendingPathExtension("meta")
        var record = Meta()
        record.key = entry.key
        record.cls = entry.cls.rawValue
        record.status = entry.status
        record.contentType = entry.contentType
        record.headers = entry.headers
        record.storedAt = entry.storedAt.timeIntervalSince1970
        record.expiresAt = entry.expiresAt?.timeIntervalSince1970 ?? 0
        record.lastAccess = entry.lastAccess.timeIntervalSince1970
        record.bytes = entry.bytes
        record.servedBy = entry.servedBy
        guard let data = try? JSONEncoder().encode(record) else { return false }
        do {
            try data.write(to: metaFile, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func forget(_ key: String) {
        lock.lock()
        let entry = index.removeValue(forKey: key)
        if let entry = entry { byteCount -= entry.bytes }
        lock.unlock()
        guard let entry = entry else { return }
        try? FileManager.default.removeItem(at: entry.bodyFile)
        try? FileManager.default.removeItem(
            entry.bodyFile.deletingPathExtension().appendingPathExtension("meta"))
    }

    /// LRU by last access, bounded by both the entry count and the byte budget.
    /// Access times are flushed here rather than on every hit: a list page hits
    /// this cache dozens of times and each flush would be a small disk write on
    /// the critical path.
    func evictIfNeeded() {
        var flush: [Entry] = []
        var removals: [Entry] = []
        lock.lock()
        let flushDue = Date().timeIntervalSince(lastAccessFlush) > 3600
        if flushDue {
            lastAccessFlush = Date()
            for (key, entry) in index where entry.accessDirty {
                var updated = entry
                updated.accessDirty = false
                index[key] = updated
                flush.append(updated)
                if flush.count >= 50 { break }
            }
        }
        if index.count > config.maxEntries || byteCount > config.maxBytes {
            let ordered = index.values.sorted { $0.lastAccess < $1.lastAccess }
            var total = byteCount
            for entry in ordered {
                // `index` shrinks as we go, so its own count is the live one.
                if index.count <= config.maxEntries && total <= config.maxBytes { break }
                total -= entry.bytes
                removals.append(entry)
                index.removeValue(forKey: entry.key)
            }
            byteCount = max(0, total)
            evictions += removals.count
        }
        lock.unlock()

        for entry in flush { _ = writeMeta(entry) }
        for entry in removals {
            try? FileManager.default.removeItem(at: entry.bodyFile)
            try? FileManager.default.removeItem(
                entry.bodyFile.deletingPathExtension().appendingPathExtension("meta"))
        }
        if !removals.isEmpty {
            CAPLog.print("[SangTacHttp:cache] evicted \(removals.count) entr(ies) to stay inside "
                + "\(config.maxBytes) bytes / \(config.maxEntries) entries")
        }
    }

    func clear() -> [String: Any] {
        lock.lock()
        let entries = index
        index = [:]
        byteCount = 0
        misses = 0
        hits = 0
        staleServed = 0
        stores = 0
        rejects = 0
        evictions = 0
        revalidations = 0
        refreshedChanges = 0
        lock.unlock()
        for entry in entries.values {
            try? FileManager.default.removeItem(at: entry.bodyFile)
            try? FileManager.default.removeItem(
                entry.bodyFile.deletingPathExtension().appendingPathExtension("meta"))
        }
        return ["entries": entries.count]
    }

    func apply(config newConfig: ContentCacheConfig) {
        lock.lock()
        config = newConfig
        lock.unlock()
        newConfig.save()
        evictIfNeeded()
    }

    func stats() -> [String: Any] {
        lock.lock()
        let entries = index.count
        let bytes = byteCount
        let oldest = index.values.map { $0.lastAccess }.min()
        let snapshot: [String: Any] = [
            "ready": ready,
            "entries": entries,
            "bytes": bytes,
            "hits": hits,
            "staleServed": staleServed,
            "misses": misses,
            "stores": stores,
            "rejects": rejects,
            "evicted": evictions,
            "revalidations": revalidations,
            "refreshedChanged": refreshedChanges,
            "enabled": config.enabled,
            "maxBytes": config.maxBytes,
            "maxEntries": config.maxEntries,
            "retentionDays": config.retentionDays,
            "oldestAccess": oldest?.timeIntervalSince1970 ?? 0
        ]
        lock.unlock()
        return snapshot
    }

    // MARK: - Keys

    /**
     A stable identity for one answer.

     Three things deliberately do NOT contribute:

       * the response type the caller asked for -- the bytes are the same body;
       * the mirror hostname (`sangtacviet.app` vs `.com` vs a `dns1.…` mirror)
         for the two read endpoints, because `bestDomain()` moves between
         launches and `h=` already identifies which content server hosts the
         book. A mirror switch therefore still finds the chapter, and the worst
         case of getting this wrong is one wasted round trip;
       * anything random the site appends to defeat caches (`nocache`, `_`, `r`,
         `t`), for the same reason the `assetCache` block stabilises the asset
         URLs.

     What DOES contribute: the method, the canonical path+query, the translation
     variant taken from the Cookie header the request actually carries (a
     `transmode`/`foreignlang` change means a different language of the same
     chapter), and a hash of the POST body -- which is what makes the book list
     cacheable at all, since its `method=history` answer depends on the reader's
     own history list in the body.
     */
    static func key(cls: ContentClass, method: String, url: URL, variant: String,
                    bodyHash: String, includeHost: Bool) -> String {
        let target = canonicalTarget(url: url, cls: cls, includeHost: includeHost)
        return [cls.rawValue, method.uppercased(), target, variant, bodyHash]
            .joined(separator: "|")
    }

    /// Parameters that exist only to defeat a cache, plus the two the chapter
    /// endpoints carry for other reasons: `key=` is a token reissued by
    /// `/io/grantcontext/context` (see the class table) and `rescan=true` asks
    /// the server for a fresh copy, which must never be answered from cache.
    private static let droppedParams: Set<String> = ["nocache", "_", "r", "t", "key", "rescan"]

    static func canonicalTarget(url: URL, cls: ContentClass, includeHost: Bool) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.path
        }
        let items = (components.queryItems ?? []).filter { item in
            !droppedParams.contains(item.name.lowercased())
        }
        components.queryItems = items.isEmpty ? nil : items
        let path = components.percentEncodedPath
        let query = components.percentEncodedQuery.map { "?" + $0 } ?? ""
        guard includeHost else { return path + query }
        let scheme = components.scheme ?? "https"
        let host = components.host ?? ""
        return scheme + "://" + host + path + query
    }

    static func bodyHash(_ body: Data?) -> String {
        guard let body = body, !body.isEmpty else { return "-" }
        let digest = SHA256.hash(data: body)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    static func hashHex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Body guards

    private static func stripped(_ body: Data) -> Data {
        // JSONSerialization tolerates a UTF-8 BOM, but the site's own reader
        // strips one explicitly (app.v2.read.js:577), so match that.
        if body.count >= 3, body[body.startIndex] == 0xEF,
           body[body.startIndex + 1] == 0xBB, body[body.startIndex + 2] == 0xBF {
            return Data(body.dropFirst(3))
        }
        return body
    }

    private static func jsonObject(_ body: Data) -> [String: Any]? {
        let data = stripped(body)
        guard let parsed = try? JSONSerialization.jsonObject(with: data,
                                                             options: [.fragmentsAllowed]) else {
            return nil
        }
        return parsed as? [String: Any]
    }

    /// The numeric value of a JSON `code`, whether the server sent `0` or `"0"`.
    private static func code(_ object: [String: Any]) -> Int? {
        guard let raw = object["code"] else { return nil }
        if let number = raw as? NSNumber { return number.intValue }
        if let text = raw as? String { return Int(text) }
        return nil
    }

    /**
     A real chapter is `{"code":0,"data":"<prose>"}` -- that is exactly the test
     the three display classes make before rendering (`chapterdisplay.js:790`,
     `:1813`, `:3682`).

     Tightening this from the old session-cache rule matters now that the answer
     is kept for 30 days: a paywall (15/18/19), a captcha (21), a login prompt
     (12/13), a busy mirror (10001/10002) or a Cloudflare interstitial all have
     to be refused, because a stored one would be served for a month.
     */
    static func isChapterBody(_ body: Data, _ contentType: String) -> Bool {
        guard body.count >= 4096 else { return false }
        guard !contentType.lowercased().contains("text/html") else { return false }
        guard let object = jsonObject(body) else { return false }
        guard code(object) == 0 else { return false }
        guard let text = object["data"] as? String, text.count >= 256 else { return false }
        return true
    }

    /**
     The chapter list's own signature: `{"code":1,"data":"1-/-<id>-/-<name>-/-…"}`.
     `code == 1` *and* a string `data` carrying the site's own `-/-` separator must
     both hold.
     */
    static func isChapterListBody(_ body: Data, _ contentType: String) -> Bool {
        guard let object = jsonObject(body), code(object) == 1,
              let list = object["data"] as? String, list.contains("-/-") else {
            return false
        }
        return true
    }

    /// The generic gate for the JSON endpoints. An empty container, an error
    /// code in the range the site uses for failures, or a bot challenge is not
    /// something to serve for a day.
    static func isJSONBody(_ body: Data, _ contentType: String) -> Bool {
        let lowered = contentType.lowercased()
        if lowered.contains("text/html") { return false }
        let data = stripped(body)
        guard data.count >= 64 else { return false }
        guard let parsed = try? JSONSerialization.jsonObject(with: data,
                                                             options: [.fragmentsAllowed]) else {
            return false
        }
        if let object = parsed as? [String: Any] {
            if object.isEmpty { return false }
            if let value = code(object), rejectionCodes.contains(value) { return false }
            if let message = object["message"] as? String,
               message.lowercased().contains("challenge_required") { return false }
            return true
        }
        if let array = parsed as? [Any] { return !array.isEmpty }
        return false
    }

    /// The codes the site uses for "you are not getting content": login walls,
    /// paywalls, captcha, a mirror that cannot serve reads, a system that is
    /// busy, and the generic 400/401/403/5xx family.
    private static let rejectionCodes: Set<Int> = [5, 7, 12, 13, 15, 18, 19, 21, 400,
                                                  401, 403, 404, 429, 500, 502, 503,
                                                  10001, 10002]

    static func isImageBody(_ body: Data, _ contentType: String) -> Bool {
        let lowered = contentType.lowercased()
        if lowered.contains("text/html") || lowered.contains("application/json") {
            return false
        }
        guard body.count >= 512 else { return false }
        if lowered.hasPrefix("image/") { return true }
        // The image hosts do not always answer with a content type on this link;
        // accept the four container formats the reader actually displays.
        guard body.count >= 8 else { return false }
        let head = [UInt8](body.prefix(12))
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF]
        let gif = Array("GIF8".utf8)
        if Array(head.prefix(4)) == png { return true }
        if Array(head.prefix(3)) == jpeg { return true }
        if Array(head.prefix(4)) == gif { return true }
        if head.count >= 12, Array(head.prefix(4)) == Array("RIFF".utf8),
           Array(head[8..<12]) == Array("WEBP".utf8) { return true }
        return false
    }
}
