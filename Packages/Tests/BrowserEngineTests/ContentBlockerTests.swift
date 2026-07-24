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

    private func blocker(
        store: WKContentRuleListStore, defaults: UserDefaults,
        seed: String? = "", fetch: @escaping (URL) async -> String? = { _ in nil },
        maxRulesPerList: Int = 50_000
    ) -> ContentBlocker {
        ContentBlocker(
            seedIdentifier: "seed-\(UUID().uuidString)", store: store, seedList: { seed },
            listURLs: [URL(string: "https://lists.test/l.txt")!], fetch: fetch,
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
        #expect(defaults.object(forKey: "contentBlocking.lastRefresh") != nil)
        #expect(defaults.string(forKey: "contentBlocking.currentIdentifier") != nil)
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
        defaults.set(Date().addingTimeInterval(-3600), forKey: "contentBlocking.lastRefresh")
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
        #expect(defaults.object(forKey: "contentBlocking.lastRefresh") == nil)
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
