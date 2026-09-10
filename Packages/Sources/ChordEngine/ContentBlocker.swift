import ChordCore
import CryptoKit
import Foundation
import WebKit

/// Compiles, caches, chunks, and weekly-refreshes the native content-blocking
/// lists (§4.8). One of the WebKit-importing engine types; the compiled
/// `WKContentRuleList`s never leave the engine — the engine attaches them to
/// each view's content controller, and nothing above sees a `WK*` type.
///
/// **The store is the cache.** `WKContentRuleListStore` persists compiled lists
/// on disk keyed by identifier, so a normal launch looks them up and attaches
/// them without re-converting or re-compiling — §6.6's "never compile on window
/// open". Compilation only happens on the first launch (seed) and on the weekly
/// refresh, off the main thread inside WebKit (`await` suspends without
/// blocking; a *main-thread-blocking* wait deadlocks, since the completion
/// handler is delivered on the main queue).
///
/// **Per-list refresh.** Each source list (EasyList, EasyPrivacy) is fetched,
/// hashed, compiled, and timed independently under its own content-hashed
/// identifier. A failure fetching one list defers only that list — its sibling
/// still updates, and the failed list keeps its last good set and retries next
/// launch rather than losing a week of updates.
///
/// **One compiled list per source list.** Each list is compiled whole into a
/// single `WKContentRuleList`, so an EasyList/EasyPrivacy `@@` exception always
/// sits in the same list as the rules it overrides. WebKit only honours
/// `ignore-previous-rules` within one compiled list — splitting a list into
/// chunks means a later chunk's exception silently cannot unblock anything (a
/// real breakage: Mixpanel's login page lost its CDN and never rendered).
/// The 100k cap is a last-resort safety valve; see `compileChunks`.
@MainActor
public final class ContentBlocker {
    private let store: WKContentRuleListStore
    private let seedIdentifier: String
    private let seedList: () -> String?

    private let listURLs: [URL]
    private let fetch: (URL) async -> String?
    private let defaults: UserDefaults
    private let now: () -> Date
    private let refreshInterval: TimeInterval
    private let maxRulesPerList: Int

    /// The compiled lists currently attached, once `activeLists()` (or a
    /// refresh) has run.
    public private(set) var compiledLists: [WKContentRuleList] = []

    /// Identifiers for the currently-registered per-list compiled sets, aligned
    /// one-to-one with `listURLs`. An empty slot (empty string) means that list
    /// has never refreshed successfully, so its slot falls back to the seed.
    /// Stored as a single array in `UserDefaults`; the old single-key format is
    /// read as a legacy fallback (a pre-per-list combined list) so an existing
    /// install keeps its cached full set until the next weekly refresh.
    private static let currentIdentifiersKey = "contentBlocking.currentIdentifiers"
    /// The pre-per-list key. Superseded by `currentIdentifiersKey`; still read
    /// for one launch so the combined cached list is not discarded on upgrade.
    private static let legacyCurrentIdentifierKey = "contentBlocking.currentIdentifier"

    /// The refresh timestamp of one list, keyed by its URL so each list ages
    /// independently — one flaky fetch must not defer the sibling by a week.
    private static func lastRefreshKey(for url: URL) -> String {
        "contentBlocking.lastRefresh.\(url.absoluteString)"
    }

    /// The persisted per-list identifier array, aligned to `listURLs`. Reads the
    /// legacy single combined identifier as a one-element array so an install
    /// upgraded from the combined format keeps its cached list; the first
    /// per-list refresh replaces it and drops the old key.
    private var currentIdentifiers: [String] {
        get {
            if let array = defaults.stringArray(forKey: Self.currentIdentifiersKey) { return array }
            if let legacy = defaults.string(forKey: Self.legacyCurrentIdentifierKey) {
                return [legacy]
            }
            return []
        }
        set {
            defaults.set(newValue, forKey: Self.currentIdentifiersKey)
            defaults.removeObject(forKey: Self.legacyCurrentIdentifierKey)
        }
    }

    /// The identifier prefix for lists compiled under the *current* compile
    /// scheme. Bumped whenever chunking semantics change, so a launch never
    /// reuses chunk files compiled under an old scheme — see
    /// `compileChunks` for why reusing them would silently keep a bug.
    private static let listIdentifierPrefix = "blocklist-v2-"

    private static func listIdentifier(for hash: String) -> String {
        listIdentifierPrefix + hash
    }

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
        // One list compiles whole, exceptions intact. ~137k rules in a single
        // list is far more transient memory than §6.2 allows and can hit an
        // uncatchable abort; ~100k compiles in well under a second with no
        // such risk, and every current list fits — EasyList ~78k, EasyPrivacy
        // ~56k — so chunking (which breaks cross-chunk `@@` exceptions, see
        // `compileChunks`) never engages for them. The cap is only the
        // safety valve for a genuinely oversized list.
        maxRulesPerList: Int = 100_000
    ) {
        self.seedIdentifier = seedIdentifier
        self.store = store
        self.seedList = seedList
        self.listURLs = listURLs
        self.fetch = fetch
        self.defaults = defaults
        self.now = now
        self.refreshInterval = refreshInterval
        self.maxRulesPerList = maxRulesPerList
    }

    /// The lists to attach right now: the cached per-list set from previous
    /// refreshes, else the bundled seed. This is the fast first-frame path — no
    /// fetch, and no recompile when cached. Crucially it re-attaches the *full*
    /// cached set on every launch, not just the seed, so blocking does not
    /// silently shrink to the seed between weekly refreshes.
    @discardableResult
    public func activeLists() async -> [WKContentRuleList] {
        var identifiers = currentIdentifiers

        // Legacy single combined list (pre-per-list): serve it verbatim. The
        // array form below cannot express it without misreading the combined
        // rules as one list's slot.
        if identifiers.count == 1, !identifiers[0].isEmpty,
            let legacy = await loadChunks(baseIdentifier: identifiers[0])
        {
            compiledLists = legacy
            return legacy
        }

        // Lists recorded under an older compile scheme would otherwise load
        // their old chunk files, silently keeping the exception-breaking split
        // this scheme exists to fix (see `compileChunks`). Force a refresh so
        // every stored list is recompiled under the current scheme; on a fetch
        // failure the old chunks serve for this launch and it retries next time.
        if identifiers.contains(where: {
            !$0.isEmpty && !$0.hasPrefix(Self.listIdentifierPrefix)
        }) {
            _ = await refreshIfDue()
            identifiers = currentIdentifiers
        }

        guard identifiers.contains(where: { !$0.isEmpty }) else {
            // Nothing ever refreshed successfully — the seed is the whole set.
            let lists = await compileChunks(from: seedList(), baseIdentifier: seedIdentifier)
            compiledLists = lists
            return lists
        }

        let lists = await fullSet(for: identifiers)
        compiledLists = lists
        return lists
    }

    /// If a week has passed (or a list has never refreshed), fetches each due
    /// list, converts and compiles it under a **content-hashed** per-list
    /// identifier, records it as current, prunes stale chunks, and returns the
    /// full refreshed set; otherwise `[]`. Each list ages and refreshes
    /// independently, so a failed fetch defers only that list — its sibling's
    /// update is still applied, and the failed list keeps its last good set and
    /// retries next launch. The hash makes an unchanged list a cache hit.
    @discardableResult
    public func refreshIfDue() async -> [WKContentRuleList] {
        var identifiers = currentIdentifiers
        var changed = false

        for (index, url) in listURLs.enumerated() {
            let last = defaults.object(forKey: Self.lastRefreshKey(for: url)) as? Date
            // A slot recorded under an older compile scheme is due even before
            // its week is up, so its list gets recompiled under the current one.
            let schemeStale = index < identifiers.count
                && !identifiers[index].isEmpty
                && !identifiers[index].hasPrefix(Self.listIdentifierPrefix)
            guard schemeStale || ContentBlockRefresh.isDue(
                lastRefresh: last, now: now(), interval: refreshInterval
            ) else { continue }

            guard let text = await fetch(url) else {
                Log.engine.error("content blocking: refresh fetch failed for \(url)")
                // Keep the slot's last good identifier — only this list retries.
                continue
            }

            let identifier = Self.listIdentifier(for: Self.shortHash(text))
            let lists: [WKContentRuleList]
            if let cached = await loadChunks(baseIdentifier: identifier) {
                lists = cached  // content unchanged since a previous refresh
            } else {
                lists = await compileChunks(from: text, baseIdentifier: identifier)
            }
            guard !lists.isEmpty else { continue }

            while identifiers.count <= index { identifiers.append("") }
            if identifiers[index] != identifier { changed = true }
            identifiers[index] = identifier
            defaults.set(now(), forKey: Self.lastRefreshKey(for: url))
        }

        guard changed else { return [] }
        defaults.set(identifiers, forKey: Self.currentIdentifiersKey)
        await pruneIdentifiers(currentBases: identifiers.filter { !$0.isEmpty })

        let lists = await fullSet(for: identifiers)
        compiledLists = lists
        return lists
    }

    /// Builds the full set to attach for a per-list identifier array, filling
    /// never-refreshed slots with the seed so blocking never silently shrinks
    /// below the seed once any list has been refreshed.
    private func fullSet(for identifiers: [String]) async -> [WKContentRuleList] {
        var all: [WKContentRuleList] = []
        if identifiers.contains(where: { $0.isEmpty }) {
            all += await loadChunks(baseIdentifier: seedIdentifier) ?? []
        }
        for id in identifiers where !id.isEmpty {
            if let chunks = await loadChunks(baseIdentifier: id) { all += chunks }
        }
        return all
    }

    // MARK: -

    /// Splits converted rules into `maxRulesPerList` chunks and compiles each
    /// under `<baseIdentifier>-<index>`, using the cache per chunk. A chunk that
    /// fails to compile is skipped — partial blocking beats none.
    ///
    /// **Chunking is the last resort, and it must never split an exception from
    /// the rules it overrides.** WebKit's `ignore-previous-rules` action (an
    /// `@@` exception line) only undoes rules compiled into the *same*
    /// `WKContentRuleList`; a later chunk is a separate list, so an exception
    /// there silently cannot unblock anything. That is exactly what happened to
    /// Mixpanel's login: EasyPrivacy's `||mxpnl.com^$third-party` landed in
    /// chunk 0 and its `@@||mxpnl.com^$domain=mixpanel.com` exception in chunk
    /// 1, so the exception never applied, Mixpanel's own CDN stayed blocked, and
    /// the page's JS (the "Login with Google" button included) never ran.
    ///
    /// The cap is therefore set high enough that each current list compiles as
    /// a single chunk (EasyList ~78k, EasyPrivacy ~56k — one ~100k-rule list
    /// compiles in well under a second with no abort). Should a list ever grow
    /// past the cap, the boundary is exception-aware: a chunk never begins with
    /// an `ignore-previous-rules` rule — leading exceptions are pulled back into
    /// the chunk holding the rules they are meant to undo.
    private func compileChunks(from text: String?, baseIdentifier: String) async
        -> [WKContentRuleList]
    {
        guard let text else { return [] }
        let rules = ContentBlockConverter.convert(text).rules
        var lists: [WKContentRuleList] = []
        var index = 0
        var start = 0
        while start < rules.count {
            var end = min(start + maxRulesPerList, rules.count)
            // A boundary landing right before an exception would orphan it: as
            // the first rule of a fresh list it has nothing to override. Pull
            // leading exceptions into the previous chunk instead.
            while end < rules.count, rules[end].action.type == .ignorePreviousRules {
                end += 1
            }
            let id = "\(baseIdentifier)-\(index)"
            if let cached = try? await store.contentRuleList(forIdentifier: id) {
                lists.append(cached)
            } else if let json = try? Array(rules[start..<end]).contentRuleListJSON(),
                let list = await compile(json: json, identifier: id, ruleCount: end - start)
            {
                lists.append(list)
            }
            start = end
            index += 1
        }
        return lists
    }

    /// Loads the cached chunks for a base identifier, `<base>-0`, `<base>-1`, …
    /// until one is missing. `nil` if none are cached.
    private func loadChunks(baseIdentifier: String) async -> [WKContentRuleList]? {
        var lists: [WKContentRuleList] = []
        var index = 0
        while let list = try? await store.contentRuleList(
            forIdentifier: "\(baseIdentifier)-\(index)")
        {
            lists.append(list)
            index += 1
        }
        return lists.isEmpty ? nil : lists
    }

    private func compile(json: String, identifier: String, ruleCount: Int) async
        -> WKContentRuleList?
    {
        do {
            let list = try await store.compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: json
            )
            Log.engine.notice(
                "content blocking: compiled \(ruleCount) rules as \(identifier)"
            )
            return list
        } catch {
            Log.engine.error("content blocking: compile failed: \(String(describing: error))")
            return nil
        }
    }

    /// Removes stale compiled lists so the store does not accumulate one set per
    /// weekly fetch. Keeps the seed's chunks and the current per-list chunks;
    /// only touches our own `blocklist-` identifiers.
    private func pruneIdentifiers(currentBases: [String]) async {
        let ids = await store.availableIdentifiers() ?? []
        for id in ids
        where id.hasPrefix("blocklist-")
            && !id.hasPrefix(seedIdentifier)
            && !currentBases.contains(where: { id.hasPrefix($0) })
        {
            try? await store.removeContentRuleList(forIdentifier: id)
        }
    }

    private static func shortHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Defaults

    /// The bundled starter list. A curated EasyList/EasyPrivacy subset so
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
