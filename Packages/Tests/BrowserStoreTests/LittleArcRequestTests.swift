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

    @Test("paneRequestedPeek lifts a click from a favourite and forwards url+space")
    func forwardsPeek() async {
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: FakeTabRepository(stored: [
                TabBuilder().url("https://fav.example").pinned(order: 0).build()
            ]),
            clock: FixedClock()
        )
        await store.restore()

        var received: [(url: URL, spaceID: UUID)] = []
        store.peekPresenter = { url, spaceID in received.append((url, spaceID)) }

        let url = URL(string: "https://peek.example")!
        let tab = store.visibleTabs[0]
        let paneID = tab.focusedPane.id
        let cancelled = store.paneRequestedPeek(url: url, fromPane: paneID)

        #expect(cancelled)
        #expect(received.count == 1)
        #expect(received[0].url == url)
        #expect(received[0].spaceID == tab.spaceID)
    }

    @Test("a click in an ephemeral tab is not a peek — it navigates normally")
    func ephemeralTabNotPeeked() async {
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: FakeTabRepository(stored: [
                TabBuilder().url("https://ephemeral.example").build()
            ]),
            clock: FixedClock()
        )
        await store.restore()

        var presented = false
        store.peekPresenter = { _, _ in presented = true }

        let paneID = store.visibleTabs[0].focusedPane.id
        let cancelled = store.paneRequestedPeek(
            url: URL(string: "https://peek.example")!, fromPane: paneID
        )

        #expect(!cancelled)
        #expect(!presented)
    }
}
