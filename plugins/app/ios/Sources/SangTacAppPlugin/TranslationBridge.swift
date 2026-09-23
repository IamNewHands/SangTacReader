import Capacitor
import Foundation
import SwiftUI
import Translation
import UIKit

/**
 iOS 18+ system translation, reached from the site patch as
 `Capacitor.Plugins.App.translationStatus / translationPrepare /
 translationTranslate`.

 Why the framework and not an HTTP engine: it is the only offline translator iOS
 exposes. No API key, no network, and it reuses the language packs the user
 already has. The JS layer still carries HTTP engines (Microsoft's keyless Edge
 channel, or the user's own Azure / Google / DeepL / OpenAI-compatible key)
 because the framework only exists from iOS 18 and because a comment written in
 a language the device has no pack for still has to go somewhere.

 Linking note: the deployment target is 15.0 while Translation is an iOS 18
 framework. Every use below sits behind @available(iOS 18.0, *), so the Swift
 compiler emits LC_LOAD_WEAK_DYLIB for it. A strong link would make dyld abort on
 iOS 15-17 before any of this code could run, and nothing in a local Windows
 build can see that -- the CI step "Verify Translation.framework is weak linked"
 re-checks it on the built binary.
 */
enum TranslationSupport {

    /**
     Declared on every iOS version on purpose. The selectors therefore always
     exist, so the JS layer gets a definite answer ("unsupported") instead of an
     opaque bridge error, and `translationTranslate` rejects so the caller can
     fall back to a network engine.

     `parent` is the Capacitor view controller: the Translation framework only
     hands a session to a SwiftUI `.translationTask`, so a 1x1 host view has to
     live somewhere in the hierarchy.
     */
    static func handle(_ method: String,
                       _ call: CAPPluginCall,
                       parent: UIViewController?) {
        guard #available(iOS 18.0, *) else {
            if method == "translate" {
                call.reject("iOS 18 以下没有系统离线翻译，请到设置里换一个联网引擎")
            } else {
                call.resolve(["status": "unsupported", "ready": false,
                              "reason": "ios-version"])
            }
            return
        }
        dispatchOnMain(method, call, parent)
    }

    /**
     Split out so an availability annotation -- not a guard -- covers the Task
     closure. A `guard #available` narrows the rest of its own scope but does not
     reliably narrow a nested closure.
     */
    @available(iOS 18.0, *)
    private static func dispatchOnMain(_ method: String,
                                       _ call: CAPPluginCall,
                                       _ parent: UIViewController?) {
        Task { @MainActor in
            AppleTranslationService.handle(method, call, parent: parent)
        }
    }
}

enum AppleTranslationError: LocalizedError {
    case timeout

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "系统翻译初始化超时，请重试"
        }
    }
}

/**
 A permanent 1x1 hidden host view.

 The Translation framework only hands out a `TranslationSession` inside a SwiftUI
 `.translationTask` closure, and only that session can ask the system to download
 a missing language pack. So one near-invisible view is mounted once and lends
 its session to every Capacitor call.
 */
@available(iOS 18.0, *)
struct AppleTranslationHostView: View {
    @ObservedObject var host: AppleTranslationHost

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(host.configuration) { session in
                host.adopt(session: session)
            }
    }
}

/**
 Lends and reuses `TranslationSession`.

 One session serves one language pair and any number of consecutive texts. When
 the pair changes -- or a call failed -- the session is dropped and a new one is
 requested: reusing a session after its configuration changed is a fatalError
 inside the framework, so it has to be released before the configuration moves.
 */
@available(iOS 18.0, *)
@MainActor
final class AppleTranslationHost: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?

    private struct PendingRequest {
        let id: UUID
        let continuation: CheckedContinuation<TranslationSession, Error>
    }

    private var session: TranslationSession?
    private var sessionKey: String?
    private var prepared: Set<String> = []
    private var pending: [PendingRequest] = []
    /// The 30s acquisition deadline for each in-flight request, so it can be
    /// cancelled the moment that request resolves.
    private var deadlines: [UUID: Task<Void, Never>] = []
    private var requestedKey: String?
    private var hostController: UIHostingController<AppleTranslationHostView>?

    /// Session acquisition only. The language-pack download itself is unbounded:
    /// it is a system sheet the user may sit on for a minute.
    private static let acquireTimeout: TimeInterval = 30

    /// A nil source means "detect it", which is a different session than any
    /// explicit pair, so it gets its own key.
    nonisolated static func key(source: Locale.Language?, target: Locale.Language) -> String {
        let from = source?.minimalIdentifier ?? "auto"
        return from + "->" + target.minimalIdentifier
    }

    /// `.translationTask` only runs once the view is actually in the hierarchy.
    func attach(to parent: UIViewController?) {
        guard hostController == nil, let parent = parent else { return }
        let controller = UIHostingController(rootView: AppleTranslationHostView(host: self))
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        controller.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        parent.addChild(controller)
        parent.view.addSubview(controller.view)
        controller.didMove(toParent: parent)
        hostController = controller
    }

    func session(for key: String,
                 source: Locale.Language?,
                 target: Locale.Language) async throws -> TranslationSession {
        if let cached = session, sessionKey == key { return cached }

        let requestId = UUID()
        let timeout = Self.acquireTimeout
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(PendingRequest(id: requestId, continuation: continuation))
            requestedKey = key
            // Drop the old session first: a configuration change invalidates it.
            session = nil
            sessionKey = nil
            // nil, then the new value on the next runloop turn. SwiftUI only
            // re-runs the action when the configuration really changes, so a
            // second request for the same pair would otherwise hang.
            configuration = nil
            Task { @MainActor in
                guard !self.pending.isEmpty else { return }
                self.configuration = TranslationSession.Configuration(source: source,
                                                                     target: target)
            }
            // Cancelled by adopt()/fail(). Without that, every acquisition left a
            // 30s sleep running: a long session accumulated one sleeping task per
            // configuration change, each waking up only to call a no-op fail().
            // (It did not keep the host alive -- that is a static singleton -- so
            // this is about the tasks, not about retention.)
            deadlines[requestId] = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch {
                    return
                }
                self?.fail(requestId: requestId, error: AppleTranslationError.timeout)
            }
        }
    }

    func adopt(session: TranslationSession) {
        self.session = session
        sessionKey = requestedKey
        let waiting = pending
        pending = []
        for request in waiting {
            cancelDeadline(request.id)
            request.continuation.resume(returning: session)
        }
    }

    /// A session that errored is not reused; dropping it makes the next call
    /// rebuild. The prepared flag goes with it, so the pack prompt can re-run.
    func discardSession() {
        session = nil
        sessionKey = nil
        prepared.removeAll()
    }

    func isPrepared(_ key: String) -> Bool { prepared.contains(key) }

    func markPrepared(_ key: String) { prepared.insert(key) }

    private func fail(requestId: UUID, error: Error) {
        guard let index = pending.firstIndex(where: { $0.id == requestId }) else { return }
        let request = pending.remove(at: index)
        cancelDeadline(requestId)
        request.continuation.resume(throwing: error)
    }

    private func cancelDeadline(_ requestId: UUID) {
        deadlines.removeValue(forKey: requestId)?.cancel()
    }
}

@available(iOS 18.0, *)
@MainActor
enum AppleTranslationService {
    private static let host = AppleTranslationHost()

    static func handle(_ method: String,
                       _ call: CAPPluginCall,
                       parent: UIViewController?) {
        host.attach(to: parent)
        switch method {
        case "status": status(call)
        case "prepare": prepare(call)
        default: translate(call)
        }
    }

    // MARK: - Parameters and payloads

    /// `auto`, an empty value or a missing value all mean "let the framework
    /// work it out", which is the common case for a comment written in whatever
    /// language its author felt like using.
    private static func language(_ raw: String?) -> Locale.Language? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw != "auto" else { return nil }
        return Locale.Language(identifier: raw)
    }

    private static func payload(_ status: LanguageAvailability.Status) -> [String: Any] {
        switch status {
        case .installed:
            return ["status": "installed", "ready": true]
        case .supported:
            return ["status": "supported", "ready": false]
        case .unsupported:
            return ["status": "unsupported", "ready": false]
        @unknown default:
            return ["status": "unsupported", "ready": false]
        }
    }

    private static func autoPayload() -> [String: Any] {
        return ["status": "unknown", "ready": true, "reason": "auto"]
    }

    private static func message(for error: Error) -> String {
        if let own = error as? AppleTranslationError, let text = own.errorDescription {
            return text
        }
        return "系统翻译失败：" + error.localizedDescription
    }

    // MARK: - Methods

    private static func status(_ call: CAPPluginCall) {
        guard let target = language(call.getString("target")) else {
            call.resolve(["status": "unsupported", "ready": false, "reason": "no-target"])
            return
        }
        guard let source = language(call.getString("source")) else {
            // Availability is answered per language pair, so with auto-detection
            // there is nothing to ask until the text is in hand. Report "ready"
            // and let the first translate() raise the pack prompt it needs.
            call.resolve(autoPayload())
            return
        }
        Task {
            let status = await LanguageAvailability().status(from: source, to: target)
            call.resolve(payload(status))
        }
    }

    private static func prepare(_ call: CAPPluginCall) {
        guard let target = language(call.getString("target")) else {
            call.reject("缺少目标语言")
            return
        }
        let source = language(call.getString("source"))
        Task {
            do {
                let pairKey = AppleTranslationHost.key(source: source, target: target)
                let session = try await host.session(for: pairKey, source: source, target: target)
                try await session.prepareTranslation()
                host.markPrepared(pairKey)
                if let source = source {
                    let status = await LanguageAvailability().status(from: source, to: target)
                    call.resolve(payload(status))
                } else {
                    call.resolve(autoPayload())
                }
            } catch {
                host.discardSession()
                call.reject(message(for: error))
            }
        }
    }

    private static func translate(_ call: CAPPluginCall) {
        guard let target = language(call.getString("target")) else {
            call.reject("缺少目标语言")
            return
        }
        let source = language(call.getString("source"))
        let texts = call.getArray("texts", String.self) ?? []
        guard !texts.isEmpty else {
            call.reject("缺少待翻译文本")
            return
        }
        Task {
            do {
                let pairKey = AppleTranslationHost.key(source: source, target: target)
                let session = try await host.session(for: pairKey, source: source, target: target)
                // prepareTranslation() is what raises the system language-pack
                // prompt, so the first translation of a new pair self-heals
                // instead of failing with a bare error.
                if !host.isPrepared(pairKey) {
                    try await session.prepareTranslation()
                    host.markPrepared(pairKey)
                }
                let requests = texts.enumerated().map { index, text in
                    TranslationSession.Request(sourceText: text,
                                               clientIdentifier: String(index))
                }
                let responses = try await session.translations(from: requests)
                // Anything the framework did not answer keeps its original text
                // rather than failing the whole batch.
                var translations = texts
                for response in responses {
                    guard let identifier = response.clientIdentifier,
                          let index = Int(identifier),
                          translations.indices.contains(index) else { continue }
                    translations[index] = response.targetText
                }
                call.resolve(["translations": translations])
            } catch {
                host.discardSession()
                call.reject(message(for: error))
            }
        }
    }
}
