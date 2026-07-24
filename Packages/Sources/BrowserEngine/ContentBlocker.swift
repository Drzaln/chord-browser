import BrowserCore
import CryptoKit
import Foundation
import WebKit

/// Compiles, caches, and weekly-refreshes the native content-blocking list
/// (§4.8, milestones C2–C3). One of the WebKit-importing engine types; the
/// compiled `WKContentRuleList` never leaves the engine — the engine attaches it
/// to each view's content controller, and nothing above sees a `WK*` type.
///
/// **The store is the cache.** `WKContentRuleListStore` persists a compiled list
/// on disk keyed by identifier, so after the first launch `prepare()` looks the
/// list up and returns it without re-converting or re-compiling — §6.6's "never
/// compile on window open". Compilation only happens on the first launch (seed)
/// and on the weekly refresh, and it runs off the main thread inside WebKit —
/// `await` suspends without blocking (a *main-thread-blocking* wait deadlocks,
/// because the completion handler is delivered on the main queue).
@MainActor
public final class ContentBlocker {
    private let store: WKContentRuleListStore
    private let seedIdentifier: String
    private let seedList: () -> String?

    // Refresh (C3)
    private let listURLs: [URL]
    private let fetch: (URL) async -> String?
    private let defaults: UserDefaults
    private let now: () -> Date
    private let refreshInterval: TimeInterval
    private let maxRules: Int
    private var currentIdentifier: String

    /// The compiled list once `prepare()` (or a refresh) has run, else `nil`.
    public private(set) var compiledList: WKContentRuleList?

    private static let lastRefreshKey = "contentBlocking.lastRefresh"

    /// The public EasyList + EasyPrivacy sources (§4.8).
    public static let defaultListURLs = [
        URL(string: "https://easylist.to/easylist/easylist.txt")!,
        URL(string: "https://easylist.to/easylist/easyprivacy.txt")!,
    ]

    public init(
        seedIdentifier: String = "blocklist-seed-v1",
        store: WKContentRuleListStore = .default(),
        seedList: @escaping () -> String? = ContentBlocker.bundledSeedList,
        listURLs: [URL] = ContentBlocker.defaultListURLs,
        fetch: @escaping (URL) async -> String? = ContentBlocker.fetch,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        refreshInterval: TimeInterval = ContentBlockRefresh.interval,
        // The real EasyList + EasyPrivacy convert to ~137k rules (verified live:
        // 138,632 lines → 137,687 rules, 945 skipped — 99.3% coverage). Compiling
        // the whole set is far more transient memory than §6.2 allows; 50k
        // compiles reliably in ~1.4 s and is the practical cap for one list.
        // EasyList is roughly most-important-first, so the kept head is the
        // high-value rules. Chunking into several lists to capture the tail is a
        // possible later enhancement — measure memory in C4 first.
        maxRules: Int = 50_000
    ) {
        self.seedIdentifier = seedIdentifier
        self.store = store
        self.seedList = seedList
        self.listURLs = listURLs
        self.fetch = fetch
        self.defaults = defaults
        self.now = now
        self.refreshInterval = refreshInterval
        self.maxRules = maxRules
        self.currentIdentifier = seedIdentifier
    }

    /// Returns the compiled seed list, using the on-disk cache when present and
    /// compiling from the seed only when it is not. This is the fast first-frame
    /// path; the fuller fetched list arrives later via `refreshIfDue()`.
    @discardableResult
    public func prepare() async -> WKContentRuleList? {
        if let cached = try? await store.contentRuleList(forIdentifier: seedIdentifier) {
            compiledList = cached
            return cached
        }
        guard let text = seedList() else {
            Log.engine.error("content blocking: no seed list available")
            return nil
        }
        let list = await compile(text, identifier: seedIdentifier, label: "seed")
        compiledList = list
        return list
    }

    /// If a week has passed (or we have never refreshed), fetches the full
    /// EasyList/EasyPrivacy, converts, compiles under a **content-hashed**
    /// identifier, and returns the new list; otherwise `nil`. The hash means an
    /// unchanged list is a cache hit, and old lists are pruned from the store.
    /// A fetch failure leaves the last-refresh date untouched, so it retries on
    /// the next launch rather than waiting a week.
    @discardableResult
    public func refreshIfDue() async -> WKContentRuleList? {
        let last = defaults.object(forKey: Self.lastRefreshKey) as? Date
        guard ContentBlockRefresh.isDue(lastRefresh: last, now: now(), interval: refreshInterval)
        else { return nil }

        var combined = ""
        for url in listURLs {
            guard let text = await fetch(url) else {
                Log.engine.error("content blocking: refresh fetch failed for \(url, privacy: .public)")
                return nil
            }
            combined += text
            combined += "\n"
        }

        let identifier = "blocklist-" + Self.shortHash(combined)
        let list: WKContentRuleList?
        if let cached = try? await store.contentRuleList(forIdentifier: identifier) {
            list = cached  // content unchanged since a previous refresh
        } else {
            let converted = ContentBlockConverter.convert(combined)
            let rules = Array(converted.rules.prefix(maxRules))
            guard let json = try? rules.contentRuleListJSON() else { return nil }
            list = await compile(json: json, identifier: identifier, ruleCount: rules.count)
        }

        guard let list else { return nil }
        compiledList = list
        currentIdentifier = identifier
        defaults.set(now(), forKey: Self.lastRefreshKey)
        await pruneIdentifiers(keeping: [identifier, seedIdentifier])
        return list
    }

    // MARK: -

    private func compile(_ filterText: String, identifier: String, label: String) async
        -> WKContentRuleList?
    {
        let converted = ContentBlockConverter.convert(filterText)
        guard let json = try? converted.rules.contentRuleListJSON() else {
            Log.engine.error("content blocking: could not serialise \(label, privacy: .public) rules")
            return nil
        }
        return await compile(json: json, identifier: identifier, ruleCount: converted.rules.count)
    }

    private func compile(json: String, identifier: String, ruleCount: Int) async
        -> WKContentRuleList?
    {
        do {
            let list = try await store.compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: json
            )
            Log.engine.notice(
                "content blocking: compiled \(ruleCount, privacy: .public) rules as \(identifier, privacy: .public)"
            )
            return list
        } catch {
            Log.engine.error("content blocking: compile failed: \(String(describing: error))")
            return nil
        }
    }

    /// Removes stale compiled lists so the store does not accumulate one per
    /// weekly fetch. Only touches our own `blocklist-` identifiers.
    private func pruneIdentifiers(keeping keep: Set<String>) async {
        let ids = await store.availableIdentifiers() ?? []
        for id in ids where id.hasPrefix("blocklist-") && !keep.contains(id) {
            try? await store.removeContentRuleList(forIdentifier: id)
        }
    }

    private static func shortHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Defaults

    /// The bundled starter list (C2). A curated EasyList/EasyPrivacy subset so
    /// blocking works on first launch, offline; the refresh replaces it with the
    /// full fetched lists.
    public nonisolated static func bundledSeedList() -> String? {
        guard let url = Bundle.module.url(forResource: "seed-blocklist", withExtension: "txt")
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The default network fetch: a plain GET, UTF-8 body on HTTP 200.
    public nonisolated static func fetch(_ url: URL) async -> String? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
