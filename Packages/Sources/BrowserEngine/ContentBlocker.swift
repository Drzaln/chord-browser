import BrowserCore
import Foundation
import WebKit

/// Compiles and caches the native content-blocking rule list (§4.8, milestone
/// C2). One of the WebKit-importing engine types; the compiled
/// `WKContentRuleList` never leaves the engine — the engine attaches it to each
/// view's content controller, and nothing above sees a `WK*` type.
///
/// **The store is the cache.** `WKContentRuleListStore` persists a compiled list
/// on disk keyed by identifier, so after the first launch `prepare()` looks the
/// list up and returns it without re-converting or re-compiling — §6.6's "never
/// compile on window open". Compilation only happens on the first launch (and,
/// from C3, on the weekly refresh under a new identifier), and it runs off the
/// main thread inside WebKit — `await` suspends without blocking (the C1
/// throwaway proved a *main-thread-blocking* wait deadlocks, because the
/// completion handler is delivered on the main queue).
@MainActor
public final class ContentBlocker {
    private let store: WKContentRuleListStore
    private let identifier: String
    private let seedList: () -> String?

    /// The compiled list once `prepare()` has run, else `nil`.
    public private(set) var compiledList: WKContentRuleList?

    public init(
        identifier: String = "blocklist-seed-v1",
        store: WKContentRuleListStore = .default(),
        seedList: @escaping () -> String? = ContentBlocker.bundledSeedList
    ) {
        self.identifier = identifier
        self.store = store
        self.seedList = seedList
    }

    /// Returns the compiled list, using the on-disk cache when present and
    /// compiling from the seed list only when it is not.
    @discardableResult
    public func prepare() async -> WKContentRuleList? {
        if let cached = try? await store.contentRuleList(forIdentifier: identifier) {
            compiledList = cached
            return cached
        }
        guard let text = seedList() else {
            Log.engine.error("content blocking: no seed list available")
            return nil
        }
        let converted = ContentBlockConverter.convert(text)
        guard let json = try? converted.rules.contentRuleListJSON() else {
            Log.engine.error("content blocking: could not serialise rules")
            return nil
        }
        do {
            let list = try await store.compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: json
            )
            compiledList = list
            Log.engine.notice(
                "content blocking: compiled \(converted.rules.count, privacy: .public) rules, \(converted.skipped, privacy: .public) filters skipped"
            )
            return list
        } catch {
            Log.engine.error("content blocking: compile failed: \(String(describing: error))")
            return nil
        }
    }

    /// The bundled starter list (C2). A curated EasyList/EasyPrivacy subset so
    /// blocking works on first launch, offline; C3 replaces it with the full
    /// fetched lists.
    public nonisolated static func bundledSeedList() -> String? {
        guard let url = Bundle.module.url(forResource: "seed-blocklist", withExtension: "txt")
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
