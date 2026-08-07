import BrowserCore
import Foundation
import Testing
import WebKit

@testable import BrowserEngine

/// Compiling, caching, chunking, and refreshing the native content-blocking
/// lists against real WebKit. Each test uses its own on-disk store and its own
/// `UserDefaults` suite, so nothing touches the app's real state.
@MainActor
struct ContentBlockerTests {
    private func tempStore() -> (WKContentRuleListStore, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "cbstore-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (WKContentRuleListStore(url: dir), { try? FileManager.default.removeItem(at: dir) })
    }

    private func tempDefaults() -> (UserDefaults, cleanup: () -> Void) {
        let name = "cbtest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    private let easyList = URL(string: "https://lists.test/easylist.txt")!
    private let easyPrivacy = URL(string: "https://lists.test/easyprivacy.txt")!

    private func blocker(
        store: WKContentRuleListStore, defaults: UserDefaults,
        seed: String? = "", fetch: @escaping (URL) async -> String? = { _ in nil },
        listURLs: [URL] = [URL(string: "https://lists.test/l.txt")!],
        maxRulesPerList: Int = 50_000
    ) -> ContentBlocker {
        ContentBlocker(
            seedIdentifier: "seed-\(UUID().uuidString)", store: store, seedList: { seed },
            listURLs: listURLs, fetch: fetch,
            defaults: defaults, now: { Date() }, maxRulesPerList: maxRulesPerList
        )
    }

    // MARK: - Seed / active lists

    @Test("The bundled seed compiles on first launch")
    func compilesBundledSeed() async throws {
        let (store, c1) = tempStore()
        let (defaults, c2) = tempDefaults()
        defer { c1(); c2() }
        let b = ContentBlocker(
            seedIdentifier: "seed-\(UUID().uuidString)", store: store, defaults: defaults)

        let lists = await b.activeLists()
        #expect(!lists.isEmpty)
        #expect(!b.compiledLists.isEmpty)
    }

    @Test("A comments-only seed compiles to nothing without trapping")
    func emptySeed() async throws {
        let (store, c1) = tempStore()
        let (defaults, c2) = tempDefaults()
        defer { c1(); c2() }
        let b = blocker(store: store, defaults: defaults, seed: "! comment\n[Adblock Plus 2.0]")
        _ = await b.activeLists()  // must not trap
    }

    @Test("Inline seed rules compile")
    func compilesInlineRules() async throws {
        let (store, c1) = tempStore()
        let (defaults, c2) = tempDefaults()
        defer { c1(); c2() }
        let b = blocker(
            store: store, defaults: defaults, seed: "||doubleclick.net^$third-party\n##.ad-banner")
        #expect(!(await b.activeLists()).isEmpty)
    }

    // MARK: - Weekly refresh + the day-2 cache re-attach

    @Test("A due refresh fetches, compiles, and records the date + identifier")
    func refreshWhenDue() async throws {
        let (store, c1) = tempStore()
        let (defaults, c2) = tempDefaults()
        defer { c1(); c2() }
        var fetched = 0
        let b = blocker(
            store: store, defaults: defaults,
            fetch: { _ in fetched += 1; return "||ads.example.com^\n||track.example.com^" })

        let lists = await b.refreshIfDue()
        #expect(!lists.isEmpty)
        #expect(fetched == 1)
        let url = URL(string: "https://lists.test/l.txt")!
        #expect(
            defaults.object(forKey: "contentBlocking.lastRefresh.\(url.absoluteString)") != nil)
        #expect(defaults.stringArray(forKey: "contentBlocking.currentIdentifiers")?.count == 1)
        // A second call is not due.
        #expect((await b.refreshIfDue()).isEmpty)
    }

    @Test("A later launch re-attaches the cached full list without refetching")
    func reattachesCachedFullList() async throws {
        let (store, c1) = tempStore()
        let (defaults, c2) = tempDefaults()
        defer { c1(); c2() }
        // First "launch": refresh compiles the full list and records it current.
        _ = await blocker(
            store: store, defaults: defaults,
            fetch: { _ in "||ads.example.com^\n||track.example.com^" }
        ).refreshIfDue()

        // Second "launch": a new blocker whose fetch would fail and whose seed is
        // empty still gets the full cached list back via activeLists() — the
        // day-2 regression this guards against gave you only the seed.
        var fetched = 0
        let b2 = blocker(
            store: store, defaults: defaults, seed: "",
            fetch: { _ in fetched += 1; return nil })
        let lists = await b2.activeLists()
        #expect(!lists.isEmpty)
        #expect(fetched == 0)  // served from cache, no network
    }

    @Test("A refresh within the interval is skipped without fetching")
    func refreshNotDue() async throws {
        let (store, c1) = tempStore()
        let (defaults, c2) = tempDefaults()
        defer { c1(); c2() }
        let url = URL(string: "https://lists.test/l.txt")!
        defaults.set(
            Date().addingTimeInterval(-3600),
            forKey: "contentBlocking.lastRefresh.\(url.absoluteString)")
        var fetched = 0
        let b = blocker(store: store, defaults: defaults, fetch: { _ in fetched += 1; return "" })
        #expect((await b.refreshIfDue()).isEmpty)
        #expect(fetched == 0)
    }

    @Test("A fetch failure does not record a refresh date, so it retries")
    func fetchFailureRetries() async throws {
        let (store, c1) = tempStore()
        let (defaults, c2) = tempDefaults()
        defer { c1(); c2() }
        let b = blocker(store: store, defaults: defaults, fetch: { _ in nil })
        #expect((await b.refreshIfDue()).isEmpty)
        let url = URL(string: "https://lists.test/l.txt")!
        #expect(
            defaults.object(forKey: "contentBlocking.lastRefresh.\(url.absoluteString)") == nil)
    }

    // MARK: - Per-list independence

    @Test("A failing list does not defer its sibling's refresh")
    func perListFailureKeepsSiblingUpToDate() async throws {
        let (store, c1) = tempStore()
        let (defaults, c2) = tempDefaults()
        defer { c1(); c2() }
        let b = blocker(
            store: store, defaults: defaults,
            fetch: { url in
                if url == easyPrivacy { return "||track.example.com^" }
                return nil  // easyList fails
            },
            listURLs: [easyList, easyPrivacy])

        let lists = await b.refreshIfDue()
        #expect(!lists.isEmpty, "the surviving list must still update")
        #expect(
            defaults.object(
                forKey: "contentBlocking.lastRefresh.\(easyPrivacy.absoluteString)") != nil)
        #expect(
            defaults.object(forKey: "contentBlocking.lastRefresh.\(easyList.absoluteString)") == nil)
        let ids = defaults.stringArray(forKey: "contentBlocking.currentIdentifiers") ?? []
        #expect(ids.count == 2)
        #expect(ids[0].isEmpty, "the failed slot stays empty so the seed fills it")
        #expect(ids[1].hasPrefix("blocklist-"))
    }

    @Test("A change to one list leaves the sibling's cache identifier intact")
    func perListChangeDoesNotInvalidateSiblingCache() async throws {
        let (store, c1) = tempStore()
        let (defaults, c2) = tempDefaults()
        defer { c1(); c2() }
        // Week 0: both refresh with distinct content.
        _ = await blocker(
            store: store, defaults: defaults,
            fetch: { url in
                url == easyList ? "||ads.example.com^" : "||privacy.example.com^"
            },
            listURLs: [easyList, easyPrivacy]
        ).refreshIfDue()
        let ids0 = defaults.stringArray(forKey: "contentBlocking.currentIdentifiers") ?? []
        #expect(ids0.count == 2)
        #expect(ids0[0] != ids0[1])

        // Week 1: both due; easyList changes, easyPrivacy is byte-identical.
        let lastWeek = Date().addingTimeInterval(-8 * 24 * 3600)
        defaults.set(lastWeek, forKey: "contentBlocking.lastRefresh.\(easyList.absoluteString)")
        defaults.set(
            lastWeek, forKey: "contentBlocking.lastRefresh.\(easyPrivacy.absoluteString)")
        _ = await blocker(
            store: store, defaults: defaults,
            fetch: { url in
                url == easyList ? "||NEW.example.com^\n||ads.example.com^" : "||privacy.example.com^"
            },
            listURLs: [easyList, easyPrivacy]
        ).refreshIfDue()
        let ids1 = defaults.stringArray(forKey: "contentBlocking.currentIdentifiers") ?? []
        #expect(ids1.count == 2)
        #expect(ids1[0] != ids0[0], "the changed list gets a new identifier")
        #expect(ids1[1] == ids0[1], "the unchanged list keeps its cache identifier")
    }

    @Test("A slot keeps its last good identifier when a later refresh fails")
    func failedSlotKeepsLastGoodIdentifier() async throws {
        let (store, c1) = tempStore()
        let (defaults, c2) = tempDefaults()
        defer { c1(); c2() }
        // Week 0: both refresh fine.
        _ = await blocker(
            store: store, defaults: defaults,
            fetch: { url in
                url == easyList ? "||ads.example.com^" : "||privacy.example.com^"
            },
            listURLs: [easyList, easyPrivacy]
        ).refreshIfDue()
        let ids0 = defaults.stringArray(forKey: "contentBlocking.currentIdentifiers") ?? []

        // Week 1: both due; easyList fails, easyPrivacy changes.
        let lastWeek = Date().addingTimeInterval(-8 * 24 * 3600)
        defaults.set(lastWeek, forKey: "contentBlocking.lastRefresh.\(easyList.absoluteString)")
        defaults.set(
            lastWeek, forKey: "contentBlocking.lastRefresh.\(easyPrivacy.absoluteString)")
        let lists = await blocker(
            store: store, defaults: defaults,
            fetch: { url in
                if url == easyList { return nil }
                return "||newtrack.example.com^"
            },
            listURLs: [easyList, easyPrivacy]
        ).refreshIfDue()
        #expect(!lists.isEmpty)

        let ids1 = defaults.stringArray(forKey: "contentBlocking.currentIdentifiers") ?? []
        #expect(ids1[0] == ids0[0], "the failed slot keeps its last good identifier")
        #expect(ids1[1] != ids0[1])
    }

    // MARK: - Chunking

    @Test("A list larger than the chunk size compiles into several lists")
    func splitsIntoChunks() async throws {
        let (store, c1) = tempStore()
        let (defaults, c2) = tempDefaults()
        defer { c1(); c2() }
        // Five rules, two per list -> three chunks.
        let five = (0..<5).map { "||ads\($0).example.com^" }.joined(separator: "\n")
        let b = blocker(
            store: store, defaults: defaults, fetch: { _ in five }, maxRulesPerList: 2)

        let lists = await b.refreshIfDue()
        #expect(lists.count == 3)
    }
}
