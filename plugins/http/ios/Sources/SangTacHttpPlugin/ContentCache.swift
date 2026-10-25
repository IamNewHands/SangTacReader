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
    /// `/mobile/lang/<code>.json` -- the site's own UI strings, 5321 bytes, and
    /// the second-largest wait in the 2026-10-13 log (see the policy below).
    case siteAsset
    /// `/io/grantcontext/context?hostid&bookid` -- 844KB, and the source of the
    /// short-lived `key=` the chapter URLs carry (`app.v2.read.js:535-551`).
    case grant
}

/// Why a stored answer is worth keeping, per class. The verdict carries the
/// reason a rejection happened, because a line that only says "not the shape this
/// class accepts" cannot be acted on: the 2026-10-13 log left `userinfo.php`
/// refused with no way to tell which guard said no.
enum Acceptance {
    case accept
    case reject(String)

    var isAccepted: Bool {
        if case .accept = self { return true }
        return false
    }

    var reason: String {
        if case .reject(let text) = self { return text }
        return ""
    }
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
    let accepts: (Data, String) -> Acceptance
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
            // The one class where a stale answer is visible as a wrong number, so
            // it is only reused inside a minute-wide window -- and, for the same
            // reason, the one class whose gate is loose: see `isReusableJSON`.
            return ContentPolicy(cls: cls, ttl: min(60, cap),
                                 serveStale: false, revalidate: false,
                                 accepts: ContentCache.isReusableJSON)
        case .comment:
            return ContentPolicy(cls: cls, ttl: min(300, cap),
                                 serveStale: false, revalidate: false,
                                 accepts: ContentCache.isJSONBody)
        case .siteAsset:
            // The site's own UI strings: 5321 bytes that have not changed in
            // months, fetched through this plugin on **every** launch of the
            // 2026-10-13 log at 681-1716ms (`GET /mobile/lang/zh.json -> 200
            // application/json json 5321b in 1174ms`, 7 times in 7 launches).
            // The URLSession layer cannot help here -- the server sends no
            // validator, so `useProtocolCachePolicy` refetches every time --
            // which is why this is the one class that is worth a day of TTL on
            // 5KB: within 24h the reader pays nothing and no request is made,
            // after that they see the previous table once and it refreshes
            // behind them.
            return ContentPolicy(cls: cls, ttl: min(day, cap),
                                 serveStale: true, revalidate: true,
                                 accepts: ContentCache.isJSONBody)
        case .grant:
            // The token inside may be single-use or time-limited (unproven), so
            // this stays short: it only pays off when the reader kills and
            // reopens the app within the same quarter hour.
            return ContentPolicy(cls: cls, ttl: min(900, cap),
                                 serveStale: false, revalidate: false,
                                 accepts: ContentCache.neverStored)
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
            at: entry.bodyFile.deletingPathExtension().appendingPathExtension("meta"))
    }

    /**
     Drop every stored profile answer (`POST /mobile/userinfo.php`).

     The key tells signed-in from signed-out (`chapterVariant` ends in `|in` or
     `|out`) but it cannot tell one account from another, and its 60-second TTL
     is long enough to see the switch: sign out, sign in as someone else, and the
     `|in` entry written for the first reader is still on disk. Signing in is the
     one moment that becomes visible, so the plugin drops the class there rather
     than keying on values the server reissues.

     Returns how many entries were dropped, for the log line that proves it ran.
     */
    @discardableResult
    func forgetProfiles() -> Int {
        lock.lock()
        let keys = index.compactMap { $0.value.cls == .userInfo ? $0.key : nil }
        lock.unlock()
        for key in keys { forget(key) }
        return keys.count
    }

    // MARK: - Refusals that outlive the process

    /// How long a refusal written to disk is trusted. Fixed, not sliding: a hit
    /// does not push the deadline out, so a cover that is drawn on every launch
    /// cannot keep its own "do not ask again" alive for the life of the install.
    static let refusalRetention: TimeInterval = 30 * 60

    /// The most records kept, oldest dropped first.
    static let refusalLimit = 64

    /// The largest refusal body worth putting on disk. A 4xx answer is a sentence
    /// or, as here, one byte; this is not a second content cache.
    static let refusalBodyCap = 8 * 1024

    static let refusalFile = "refusals.json"

    /// One refusal as it is written down and read back.
    struct RefusalRecord {
        let status: Int
        let contentType: String
        let headers: [String: String]
        let body: Data
        let at: Date
    }

    private struct PersistedRefusal: Codable {
        var key = ""
        var status = 0
        var contentType = ""
        var headers: [String: String] = [:]
        var body = ""
        var at: TimeInterval = 0
    }

    private let refusalLock = NSLock()
    private var refusalStore: [String: RefusalRecord] = [:]
    private var refusalStoreLoaded = false

    /**
     A refusal the plugin decided is worth remembering past this process.

     Why the disk half lives here and not in the plugin: this directory is this
     type's to own. `refusals.json` sits beside the `<hash>.meta`/`<hash>.body`
     pairs, `loadIndex` only ever reads `*.meta` so it is invisible to the entry
     index, and "clear the cache" has to drop it too or a clean slate would still
     answer "do not ask again" for half an hour.

     Why it exists at all: the in-process memory lasts 60 seconds, which covers
     one screen drawing the same broken cover three times, but it does not
     survive a launch -- and the round-49 device log shows exactly that hole. A
     403 at 09:53:04 was not remembered by the 09:53:46 request 42 seconds later,
     because 09:53:42 was a new process; the same process then answered
     `age=2s`/`age=4s`/`age=20s` from memory with `in 0ms (refused)`. Every cold
     launch therefore paid 853ms once, for a host that hotlink-blocks the link
     (`www.trxs.cc`).

     Why the window is short and fixed: a written-down refusal suppresses the very
     request that would disprove it, so there is no success to clear it with and
     the window is the only bound. Which is also why the caller restricts this to
     images -- the worst case there is a thumbnail for half an hour, against
     "cannot read this chapter" for the same half hour.
     */
    @discardableResult
    func storeRefusal(key: String, status: Int, contentType: String,
                      headers: [String: String], body: Data, at: Date) -> Bool {
        guard let root = root, config.enabled else { return false }
        guard status >= 400, !key.isEmpty, body.count <= ContentCache.refusalBodyCap
        else { return false }

        refusalLock.lock()
        if !refusalStoreLoaded {
            refusalStoreLoaded = true
            refusalStore = ContentCache.readRefusals(root: root)
        }
        refusalStore = refusalStore.filter {
            at.timeIntervalSince($0.value.at) < ContentCache.refusalRetention
        }
        if refusalStore.count >= ContentCache.refusalLimit,
           let oldest = refusalStore.min(by: { $0.value.at < $1.value.at })?.key {
            refusalStore.removeValue(forKey: oldest)
        }
        refusalStore[key] = RefusalRecord(status: status, contentType: contentType,
                                          headers: headers, body: body, at: at)
        let snapshot = refusalStore
        refusalLock.unlock()
        return ContentCache.writeRefusals(snapshot, root: root)
    }

    /// The refusal written down for `key`, or nil when there is none or it has
    /// aged out. The age is checked here and not only at load time: a process can
    /// run for hours, and a record read at launch must not outlive its window.
    func storedRefusal(_ key: String) -> RefusalRecord? {
        guard isEnabled else { return nil }
        guard let hit = refusalStoreSnapshot(), let record = hit[key],
              Date().timeIntervalSince(record.at) < ContentCache.refusalRetention
        else { return nil }
        return record
    }

    /// How many records are on disk and still inside their window. Part of the
    /// launch totals line, so one log answers "did that write survive the
    /// process?" even on a launch that never draws the broken image.
    var storedRefusalCount: Int {
        guard isEnabled else { return 0 }
        let now = Date()
        return (refusalStoreSnapshot() ?? [:]).values
            .filter { now.timeIntervalSince($0.at) < ContentCache.refusalRetention }.count
    }

    /// The on-disk records, read once. Returns a copy; callers never hold the
    /// lock across their own work. Named `…Snapshot` rather than `refusalStore`
    /// so it is never confused with the stored property of that name.
    private func refusalStoreSnapshot() -> [String: RefusalRecord]? {
        guard let root = root else { return nil }
        refusalLock.lock()
        defer { refusalLock.unlock() }
        if !refusalStoreLoaded {
            refusalStoreLoaded = true
            refusalStore = ContentCache.readRefusals(root: root)
        }
        return refusalStore
    }

    private func forgetRefusals(root: URL) {
        refusalLock.lock()
        refusalStore = [:]
        refusalStoreLoaded = true
        refusalLock.unlock()
        try? FileManager.default.removeItem(
            at: root.appendingPathComponent(ContentCache.refusalFile))
    }

    private static func readRefusals(root: URL?) -> [String: RefusalRecord] {
        guard let root = root,
              let data = try? Data(contentsOf: root.appendingPathComponent(refusalFile)),
              let records = try? JSONDecoder().decode([PersistedRefusal].self, from: data)
        else { return [:] }
        let now = Date()
        var loaded: [String: RefusalRecord] = [:]
        for record in records {
            guard !record.key.isEmpty, record.status >= 400,
                  let body = Data(base64Encoded: record.body) else { continue }
            let at = Date(timeIntervalSince1970: record.at)
            guard now.timeIntervalSince(at) < refusalRetention else { continue }
            loaded[record.key] = RefusalRecord(status: record.status,
                                               contentType: record.contentType,
                                               headers: record.headers, body: body, at: at)
        }
        return loaded
    }

    private static func writeRefusals(_ store: [String: RefusalRecord], root: URL) -> Bool {
        // Sorted by key so an unchanged record set produces the same bytes: a
        // file that reshuffles itself on every write is unreadable as evidence.
        var records: [PersistedRefusal] = []
        for key in store.keys.sorted() {
            guard let record = store[key] else { continue }
            var out = PersistedRefusal()
            out.key = key
            out.status = record.status
            out.contentType = record.contentType
            out.headers = record.headers
            out.body = record.body.base64EncodedString()
            out.at = record.at.timeIntervalSince1970
            records.append(out)
        }
        guard let data = try? JSONEncoder().encode(records) else { return false }
        do {
            try data.write(to: root.appendingPathComponent(refusalFile), options: .atomic)
            return true
        } catch {
            return false
        }
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
                at: entry.bodyFile.deletingPathExtension().appendingPathExtension("meta"))
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
                at: entry.bodyFile.deletingPathExtension().appendingPathExtension("meta"))
        }
        // The remembered refusals are the other thing in this directory: a user
        // asking for a clean slate should not keep a 30-minute-old "do not ask
        // again" for a cover they may have just fixed on the server.
        if let root = root { forgetRefusals(root: root) }
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
    ///
    /// Not every endpoint means a status by it: `userinfo.php` carries a
    /// top-level `code` of 400 next to the account's own `id`/`name` (round-48
    /// device log). Callers therefore read this only after positive proof of a
    /// good answer has failed to appear -- see `isReusableJSON`.
    private static func code(_ object: [String: Any]) -> Int? {
        guard let raw = object["code"] else { return nil }
        if let number = raw as? NSNumber { return number.intValue }
        if let text = raw as? String { return Int(text) }
        return nil
    }

    /**
     A real chapter is `{"code":"0","bookname":…,"data":"<prose>"}` under a
     `Content-Type: text/html; charset=utf-8` header -- the site's own contract
     (docs/capacitor-port.md:112), and the exact test the three display classes
     make before rendering (`chapterdisplay.js:790`, `:1813`, `:3682`).

     **The content type must not be part of this test.** The first version
     rejected `text/html` on the theory that it must be an error page, and the
     2026-10-13 device log shows what that cost: every real chapter came back as

         GET /?sajax=readchapter&… -> 200 text/html; charset=utf-8 string 9558b
         {"code":"0","bookname":" Người thực vật thê tử…

     and was refused as "not the shape this class accepts", so the reader
     re-downloaded every chapter on every launch while the cache stayed empty.
     The JSON shape check below is what actually excludes an error page: an HTML
     interstitial, a login page or a bot challenge does not parse as a JSON object
     with `code == 0`, so nothing has to be inferred from the header.

     **Neither may a size floor be part of this test, and that is the same mistake
     twice.** This gate used to demand a body of at least four kilobytes and a
     `data` of at least 256 characters. Both are stricter than the site, whose own
     render test is only `cdata.code == "0"` (`chapterdisplay.js:790`, `:1813`,
     `:3682` -- there is no length test anywhere in those files). The 2026-10-13
     19:38 device log shows what the floors cost: chapter `c=931037660` is the
     author's one-line notice "请假一天" -- 488 bytes, 117 characters of `data`, a
     perfectly good chapter the site renders -- and the gate refused it as "smaller
     than 4096 bytes" on every open, so it went back to the network three times in
     that one log (607ms, 546ms, and 618ms in the earlier session) while never
     being stored once. A floor can only ever reject real content: the shape checks
     below already refuse an HTML interstitial, a truncated body, a non-zero `code`
     and a non-string `data`, so the smallest surviving answer is a genuine one.
     */
    static func isChapterBody(_ body: Data, _ contentType: String) -> Acceptance {
        guard let object = jsonObject(body) else { return .reject("not a JSON object") }
        guard let value = code(object) else { return .reject("no code field") }
        guard value == 0 else { return .reject("code \(value)") }
        guard let text = object["data"] as? String else { return .reject("no data field") }
        guard !text.isEmpty else { return .reject("empty data") }
        return .accept
    }

    /**
     The chapter list's own signature: `{"code":1,"data":"1-/-<id>-/-<name>-/-…"}`.
     `code == 1` *and* a string `data` carrying the site's own `-/-` separator must
     both hold.
     */
    static func isChapterListBody(_ body: Data, _ contentType: String) -> Acceptance {
        guard let object = jsonObject(body) else { return .reject("not a JSON object") }
        guard let value = code(object) else { return .reject("no code field") }
        guard value == 1 else { return .reject("code \(value)") }
        guard let list = object["data"] as? String else { return .reject("no data field") }
        guard list.contains("-/-") else { return .reject("data carries no -/- separator") }
        return .accept
    }

    /**
     The generic gate for the JSON endpoints. An empty container, an error code in
     the range the site uses for failures, or a bot challenge is not something to
     serve for a day.

     No content-type test, for the same reason `isChapterBody` has none: every one
     of these endpoints answers `text/html; charset=utf-8` on this link while the
     body is JSON -- the 2026-10-13 log has `bookinfo.php -> 200 text/html …
     2950b {"book":{"host":"trxs",…}}`, `booklist.php?method=history -> 200
     text/html … 8398b {"list":[…]}` and `userinfo.php -> 200 text/html … 454b
     {"id":"306185",…}`, all three refused by that test while they were perfectly
     good answers. What keeps a challenge page out is that it is not JSON at all.
     */
    static func isJSONBody(_ body: Data, _ contentType: String) -> Acceptance {
        let data = stripped(body)
        guard data.count >= 64 else { return .reject("smaller than 64 bytes") }
        guard let parsed = try? JSONSerialization.jsonObject(with: data,
                                                             options: [.fragmentsAllowed]) else {
            return .reject("not JSON")
        }
        if let object = parsed as? [String: Any] {
            if object.isEmpty { return .reject("empty object") }
            if let value = code(object), rejectionCodes.contains(value) {
                return .reject("failure code \(value)")
            }
            if let message = object["message"] as? String,
               message.lowercased().contains("challenge_required") {
                return .reject("bot challenge")
            }
            return .accept
        }
        if let array = parsed as? [Any] {
            return array.isEmpty ? .reject("empty array") : .accept
        }
        return .reject("not a JSON container")
    }

    /**
     `userinfo.php` gets a looser gate than its neighbours, and the reason is its
     clock: this class is reused for 60 seconds, so the worst case of storing an
     answer we should not have kept is one wrong unread count for a minute -- while
     refusing a good one costs a 573ms round trip on every launch (2026-10-13 log,
     twice per launch). The book detail (24h) and the home lists (10min) keep the
     strict gate, where a wrong answer would outlive the mistake.

     A bot challenge is still refused here: that is the one shape that parsing
     cannot rule out on its own.

     Loose is not loose enough to read `code` as a status here. The round-48 log
     says what that cost, in the one line the new diagnostics were added to produce:

         POST …/mobile/userinfo.php not cached class=userInfo status=200 bytes=454
              content-type=text/html; charset=utf-8 (failure code 400)
              head={"id":"306185","name":"mingzihaojiandan","displayname":"@baipiao","avatar":"http…

     The head is a perfectly good signed-in profile, and the gate refused it
     because the body carries a top-level `code` of 400 that is not a status at
     all (a real `code: 400` never arrives together with the account's own `id`
     and `name`). So identity is read first, and `code` only decides when the
     answer does not name its owner -- which is exactly what a login wall looks
     like.
     */
    static func isReusableJSON(_ body: Data, _ contentType: String) -> Acceptance {
        let data = stripped(body)
        guard data.count >= 32 else { return .reject("smaller than 32 bytes") }
        guard let parsed = try? JSONSerialization.jsonObject(with: data,
                                                             options: [.fragmentsAllowed]) else {
            return .reject("not JSON")
        }
        if let object = parsed as? [String: Any] {
            if object.isEmpty { return .reject("empty object") }
            if let message = object["message"] as? String,
               message.lowercased().contains("challenge_required") {
                return .reject("bot challenge")
            }
            // Positive proof first: a real profile names its own owner, and the
            // `code` field next to it is then not a verdict on the request.
            if let identity = object["id"], !isBlankIdentity(identity) {
                return .accept
            }
            if let value = code(object), rejectionCodes.contains(value) {
                return .reject("failure code \(value)")
            }
            return .accept
        }
        if let array = parsed as? [Any] {
            return array.isEmpty ? .reject("empty array") : .accept
        }
        return .reject("not a JSON container")
    }

    /// Whether an identity field carries something rather than nothing. The site
    /// sends `"id":"306185"` as a string here and as a number on other
    /// endpoints, so both shapes have to be read.
    private static func isBlankIdentity(_ raw: Any) -> Bool {
        if let text = raw as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let number = raw as? NSNumber { return number.intValue == 0 }
        return raw is NSNull
    }

    /**
     `grantcontext` is deliberately never stored, and now says so instead of being
     refused by accident (it is obfuscated JavaScript -- `(()=>{var …})()` under
     `text/javascript`, 785-854KB in the 2026-10-13 log -- so the JSON gate above
     rejected it, which was the right outcome for the wrong reason).

     The body is what produces the `key=` that every chapter URL carries
     (`app.v2.read.js:535-551`). Whether that token survives an app restart is
     unproven, and a stale one costs a *failed chapter read*, so the asymmetric
     choice is to pay 0.6-1.6s per book switch instead of risking the reader.
     */
    static func neverStored(_ body: Data, _ contentType: String) -> Acceptance {
        return .reject("not stored by design (see the comment above)")
    }

    /// The codes the site uses for "you are not getting content": login walls,
    /// paywalls, captcha, a mirror that cannot serve reads, a system that is
    /// busy, and the generic 400/401/403/5xx family.
    private static let rejectionCodes: Set<Int> = [5, 7, 12, 13, 15, 18, 19, 21, 400,
                                                  401, 403, 404, 429, 500, 502, 503,
                                                  10001, 10002]

    /// The one class where the content type *is* informative: an image slot that
    /// answers `text/html` is a refusal, and the 2026-10-13 log is full of them
    /// (`GET https://www.trxs.cc/…jpeg -> 403 text/html base64 1b`) -- the image
    /// host refuses this link, and storing that answer would make the refusal
    /// permanent.
    static func isImageBody(_ body: Data, _ contentType: String) -> Acceptance {
        let lowered = contentType.lowercased()
        if lowered.contains("text/html") { return .reject("html in an image slot") }
        if lowered.contains("application/json") { return .reject("json in an image slot") }
        guard body.count >= 512 else { return .reject("smaller than 512 bytes") }
        if lowered.hasPrefix("image/") { return .accept }
        // The image hosts do not always answer with a content type on this link;
        // accept the four container formats the reader actually displays.
        let head = [UInt8](body.prefix(12))
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF]
        let gif = Array("GIF8".utf8)
        if Array(head.prefix(4)) == png { return .accept }
        if Array(head.prefix(3)) == jpeg { return .accept }
        if Array(head.prefix(4)) == gif { return .accept }
        if Array(head.prefix(4)) == Array("RIFF".utf8),
           Array(head[8..<12]) == Array("WEBP".utf8) { return .accept }
        return .reject("no image signature (content-type \(lowered.isEmpty ? "none" : lowered))")
    }
}
