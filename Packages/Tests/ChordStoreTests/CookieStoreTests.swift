import ChordCore
import ChordEngine
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

/// Per-site cookie inspection reaches the engine (non-spec: user-requested).
@Suite("Site cookies — store wiring")
@MainActor
struct CookieStoreTests {

    private func makeStore() -> (TabStore, FakeWebEngine) {
        let engine = FakeWebEngine()
        let store = TabStore(
            engine: engine,
            repository: FakeTabRepository(stored: []),
            clock: FixedClock()
        )
        return (store, engine)
    }

    @Test("Cookies are read from the engine for the Space")
    func readsFromEngine() async {
        let (store, engine) = makeStore()
        let space = Space(name: "Work", sortIndex: 0)
        store.spaces = [space]
        engine.siteCookies = [
            SiteCookie(
                name: "session", value: "abc", domain: "example.com", path: "/",
                isSecure: true, isHTTPOnly: true, expiresAt: nil
            )
        ]

        let cookies = await store.siteCookies(
            for: URL(string: "https://example.com/")!, inSpace: space.id
        )
        #expect(cookies.map(\.name) == ["session"])
    }

    @Test("An unknown Space yields no cookies rather than touching another")
    func unknownSpace() async {
        let (store, _) = makeStore()
        let cookies = await store.siteCookies(
            for: URL(string: "https://example.com/")!, inSpace: UUID()
        )
        #expect(cookies.isEmpty)
    }

    @Test("Clearing reaches the engine, scoped to the site")
    func clearsThroughEngine() async {
        let (store, engine) = makeStore()
        let space = Space(name: "Work", sortIndex: 0)
        store.spaces = [space]
        let url = URL(string: "https://example.com/")!

        await store.clearSiteCookies(for: url, inSpace: space.id)
        #expect(engine.clearedCookieURLs == [url])
    }
}
