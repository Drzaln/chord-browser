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
        let blocker = ContentBlocker(identifier: "seed-\(UUID().uuidString)", store: store)

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
        _ = await ContentBlocker(identifier: id, store: store, seedList: { seed }).prepare()

        // A second blocker whose seed would fail to compile still returns a list,
        // because the store already has the compiled one under this identifier.
        let cached = await ContentBlocker(
            identifier: id, store: store, seedList: { nil }
        ).prepare()
        #expect(cached != nil)
    }

    @Test("A valid rule list compiles to a usable object")
    func compilesInlineRules() async throws {
        let (store, cleanup) = tempStore()
        defer { cleanup() }
        let blocker = ContentBlocker(
            identifier: "inline-\(UUID().uuidString)", store: store,
            seedList: { "||doubleclick.net^$third-party\n##.ad-banner" }
        )
        #expect(await blocker.prepare() != nil)
    }

    @Test("A seed that yields no serialisable rules still does not crash")
    func emptySeed() async throws {
        let (store, cleanup) = tempStore()
        defer { cleanup() }
        // Only comments — zero rules. An empty rule array is still valid JSON
        // ("[]"), which WebKit accepts, so this compiles to an empty list.
        let blocker = ContentBlocker(
            identifier: "empty-\(UUID().uuidString)", store: store,
            seedList: { "! just a comment\n[Adblock Plus 2.0]" }
        )
        _ = await blocker.prepare()  // must not trap
    }
}
