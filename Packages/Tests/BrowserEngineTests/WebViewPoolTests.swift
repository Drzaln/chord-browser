import Foundation
import Testing
import WebKit

@testable import BrowserEngine

@Suite("Web view pool", .serialized)
@MainActor
struct WebViewPoolTests {

    private func makeLive(_ id: UUID) -> LiveWebView {
        LiveWebView(paneID: id, webView: WKWebView(frame: .zero), cornerRadius: 10)
    }

    @Test("The pool evicts the least recently used view over capacity")
    func evictsLRU() {
        let pool = WebViewPool(capacity: 2)
        let (a, b, c) = (UUID(), UUID(), UUID())

        pool.insert(makeLive(a))
        pool.insert(makeLive(b))
        pool.insert(makeLive(c))

        #expect(pool.count == 2)
        #expect(pool.view(for: a) == nil)   // oldest went first
        #expect(pool.view(for: c) != nil)
    }

    @Test("Touching a view protects it from the next eviction")
    func touchProtects() {
        let pool = WebViewPool(capacity: 2)
        let (a, b, c) = (UUID(), UUID(), UUID())

        pool.insert(makeLive(a))
        pool.insert(makeLive(b))
        _ = pool.view(for: a)               // a is now most recent
        pool.insert(makeLive(c))

        #expect(pool.view(for: a) != nil)
        #expect(pool.view(for: b) == nil)
    }

    @Test("The most recently used view is never evicted")
    func protectsCurrentView() {
        let pool = WebViewPool(capacity: 1)
        let (a, b) = (UUID(), UUID())

        pool.insert(makeLive(a))
        pool.insert(makeLive(b))

        // b is what the user is looking at; the cap must not take it away.
        #expect(pool.view(for: b) != nil)
    }

    @Test("willEvict fires before teardown so state can be captured")
    func willEvictFires() {
        let pool = WebViewPool(capacity: 1)
        var evicted: [UUID] = []
        pool.willEvict = { paneID, _ in evicted.append(paneID) }

        let a = UUID()
        pool.insert(makeLive(a))
        pool.insert(makeLive(UUID()))

        #expect(evicted == [a])
    }

    @Test("evictAll empties the pool")
    func evictAllEmpties() {
        let pool = WebViewPool(capacity: 12)
        for _ in 0..<4 { pool.insert(makeLive(UUID())) }

        pool.evictAll()

        #expect(pool.count == 0)
    }

    @Test("A pane can be located by its web view")
    func lookupByWebView() {
        let pool = WebViewPool(capacity: 4)
        let id = UUID()
        let live = makeLive(id)
        pool.insert(live)

        #expect(pool.paneID(matching: live.webView) == id)
        #expect(pool.paneID(matching: WKWebView(frame: .zero)) == nil)
    }
}

@Suite("Pane snapshots")
struct PaneSnapshotTests {

    @Test("A default snapshot is inert")
    func defaults() {
        let snapshot = PaneSnapshot()
        #expect(snapshot.url == nil)
        #expect(snapshot.title.isEmpty)
        #expect(!snapshot.isLoading)
        #expect(snapshot.estimatedProgress == 0)
        #expect(!snapshot.canGoBack)
        #expect(!snapshot.canGoForward)
    }

    @Test("Surfaces compare by pane identity")
    @MainActor
    func surfaceIdentity() {
        let id = UUID()
        #expect(AnyWebSurface.empty(id: id) == AnyWebSurface.empty(id: id))
        #expect(AnyWebSurface.empty(id: id) != AnyWebSurface.empty(id: UUID()))
    }
}
