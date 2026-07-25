import BrowserCore
import BrowserEngine
import BrowserTestSupport
import Foundation
import Testing

@testable import BrowserStore

/// The "Open in Little Chord" link context-menu path (non-spec: user-requested):
/// the engine delegate call must forward through the injected presenter that the
/// app layer owns.
@Suite("Little Arc request")
@MainActor
struct LittleArcRequestTests {

    @Test("paneRequestedLittleArc forwards the URL to the injected presenter")
    func forwardsToPresenter() async {
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: FakeTabRepository(stored: []),
            clock: FixedClock()
        )
        await store.restore()

        var presented: URL?
        store.littleArcPresenter = { presented = $0 }

        let url = URL(string: "https://peek.example/story")!
        store.paneRequestedLittleArc(url: url)

        #expect(presented == url)
    }

    @Test("With no presenter wired it is inert, not a crash")
    func inertWithoutPresenter() async {
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: FakeTabRepository(stored: []),
            clock: FixedClock()
        )
        await store.restore()

        store.paneRequestedLittleArc(url: URL(string: "https://example.com")!)
        // No presenter, no tab opened — a peek is not a tab.
        #expect(store.visibleTabs.allSatisfy { $0.focusedPane.url.host() != "example.com" })
    }

    @Test("paneRequestedPeek forwards show and dismiss to the peek presenter")
    func forwardsPeek() async {
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: FakeTabRepository(stored: []),
            clock: FixedClock()
        )
        await store.restore()

        var received: [URL?] = []
        store.peekPresenter = { received.append($0) }

        let url = URL(string: "https://peek.example")!
        store.paneRequestedPeek(url: url)
        store.paneRequestedPeek(url: nil)

        #expect(received.count == 2)
        #expect(received.first! == url)
        #expect(received.last! == nil)
    }
}
