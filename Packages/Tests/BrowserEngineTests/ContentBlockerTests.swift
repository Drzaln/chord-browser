import BrowserCore
import Foundation
import Testing
import WebKit

@testable import BrowserEngine

/// C2: compiling and caching the native content-blocking list against real
/// WebKit. Each test uses its own on-disk store in a temp directory and a unique
/// identifier, so nothing touches the app's real cached list.
@MainActor
struct ContentBlockerTests {
    private func tempStore() -> (WKContentRuleListStore, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "cbstore-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (WKContentRuleListStore(url: dir), { try? FileManager.default.removeItem(at: dir) })
    }

    @Test("The bundled seed list converts and compiles in real WebKit")
    func compilesBundledSeed() async throws {
        let (store, cleanup) = tempStore()
        defer { cleanup() }
        let blocker = ContentBlocker(seedIdentifier: "seed-\(UUID().uuidString)", store: store)

        let list = await blocker.prepare()
        #expect(list != nil)
        #expect(blocker.compiledList != nil)
    }

    @Test("A second prepare uses the on-disk cache, not the seed")
    func usesCacheOnSecondPrepare() async throws {
        let (store, cleanup) = tempStore()
        defer { cleanup() }
        let id = "cache-\(UUID().uuidString)"
        let seed = "||ads.example.com^\n||track.example.com^"

        // First prepare compiles from the seed.
        _ = await ContentBlocker(seedIdentifier:id, store: store, seedList: { seed }).prepare()

        // A second blocker whose seed would fail to compile still returns a list,
        // because the store already has the compiled one under this identifier.
        let cached = await ContentBlocker(
            seedIdentifier:id, store: store, seedList: { nil }
        ).prepare()
        #expect(cached != nil)
    }

    @Test("A valid rule list compiles to a usable object")
    func compilesInlineRules() async throws {
        let (store, cleanup) = tempStore()
        defer { cleanup() }
        let blocker = ContentBlocker(
            seedIdentifier:"inline-\(UUID().uuidString)", store: store,
            seedList: { "||doubleclick.net^$third-party\n##.ad-banner" }
        )
        #expect(await blocker.prepare() != nil)
    }

    // MARK: - Weekly refresh (C3)

    private func tempDefaults() -> (UserDefaults, cleanup: () -> Void) {
        let name = "cbtest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    @Test("A due refresh fetches, compiles a hashed list, and records the date")
    func refreshWhenDue() async throws {
        let (store, c1) = tempStore()
        let (defaults, c2) = tempDefaults()
        defer { c1(); c2() }
        var fetched: [URL] = []

        let blocker = ContentBlocker(
            seedIdentifier: "seed-\(UUID().uuidString)", store: store,
            seedList: { "" },
            listURLs: [URL(string: "https://lists.test/easylist.txt")!],
            fetch: { url in fetched.append(url); return "||ads.example.com^\n||track.example.com^" },
            defaults: defaults, now: { Date() }
        )

        let list = await blocker.refreshIfDue()
        #expect(list != nil)
        #expect(fetched.count == 1)
        // The date was recorded, so a second call is not due.
        #expect(defaults.object(forKey: "contentBlocking.lastRefresh") != nil)
        #expect(await blocker.refreshIfDue() == nil)
    }

    @Test("A refresh is skipped when the last one was within the interval")
    func refreshNotDue() async throws {
        let (store, c1) = tempStore()
        let (defaults, c2) = tempDefaults()
        defer { c1(); c2() }
        // Last refresh was an hour ago; the interval is a week.
        defaults.set(Date().addingTimeInterval(-3600), forKey: "contentBlocking.lastRefresh")

        var fetchCount = 0
        let blocker = ContentBlocker(
            seedIdentifier: "seed-\(UUID().uuidString)", store: store, seedList: { "" },
            fetch: { _ in fetchCount += 1; return "" },
            defaults: defaults, now: { Date() }
        )
        #expect(await blocker.refreshIfDue() == nil)
        #expect(fetchCount == 0)  // not even fetched
    }

    @Test("A fetch failure does not record a refresh date, so it retries")
    func fetchFailureRetries() async throws {
        let (store, c1) = tempStore()
        let (defaults, c2) = tempDefaults()
        defer { c1(); c2() }

        let blocker = ContentBlocker(
            seedIdentifier: "seed-\(UUID().uuidString)", store: store, seedList: { "" },
            fetch: { _ in nil },  // network down
            defaults: defaults, now: { Date() }
        )
        #expect(await blocker.refreshIfDue() == nil)
        #expect(defaults.object(forKey: "contentBlocking.lastRefresh") == nil)
    }

    @Test("A seed that yields no serialisable rules still does not crash")
    func emptySeed() async throws {
        let (store, cleanup) = tempStore()
        defer { cleanup() }
        // Only comments — zero rules. An empty rule array is still valid JSON
        // ("[]"), which WebKit accepts, so this compiles to an empty list.
        let blocker = ContentBlocker(
            seedIdentifier:"empty-\(UUID().uuidString)", store: store,
            seedList: { "! just a comment\n[Adblock Plus 2.0]" }
        )
        _ = await blocker.prepare()  // must not trap
    }
}
