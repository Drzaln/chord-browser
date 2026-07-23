import BrowserCore
import BrowserEngine
import BrowserTestSupport
import Foundation
import Testing

@testable import BrowserStore

/// Favourites are the pinned tabs of the *active* Space (4.1). The sidebar
/// renders them as a grid above the ephemeral list.
@Suite("Pinned favourites")
@MainActor
struct PinnedTests {

    private func makeStore(stored: [Tab]) async -> TabStore {
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: FakeTabRepository(stored: stored),
            clock: FixedClock()
        )
        await store.restore()
        return store
    }

    @Test("Pinned and unpinned are separated, and together are every visible tab")
    func splitsPinnedFromTheRest() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://pinned.example").pinned(order: 0).build(),
            TabBuilder().url("https://loose.example").build(),
        ])

        #expect(store.pinnedTabs.map { $0.focusedPane.url.host() } == ["pinned.example"])
        #expect(store.unpinnedTabs.map { $0.focusedPane.url.host() } == ["loose.example"])
        #expect(store.pinnedTabs.count + store.unpinnedTabs.count == store.visibleTabs.count)
    }

    /// The favourites of one Space must never show in another — that is the
    /// whole point of them being per-Space, and `visibleTabs` is what enforces
    /// it. A regression here would leak work bookmarks into a personal Space.
    @Test("A Space's favourites are invisible from another Space")
    func favouritesAreScopedToTheirSpace() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://first.example").pinned(order: 0).build()
        ])

        let first = try! #require(store.activeSpace)
        store.addSpace()
        let second = try! #require(store.spaces.first { $0.id != first.id })

        store.selectSpace(second.id)
        #expect(store.pinnedTabs.isEmpty, "the other Space's favourite must not appear here")

        store.selectSpace(first.id)
        #expect(store.pinnedTabs.count == 1)
    }

    @Test("Pinning moves a tab out of the ephemeral list, and unpinning returns it")
    func pinningMovesBetweenSections() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://a.example").build()
        ])
        let tabID = try! #require(store.tabs.first).id

        store.setPinned(true, tabID: tabID)
        #expect(store.pinnedTabs.map(\.id) == [tabID])
        #expect(store.unpinnedTabs.isEmpty)

        store.setPinned(false, tabID: tabID)
        #expect(store.pinnedTabs.isEmpty)
        #expect(store.unpinnedTabs.map(\.id) == [tabID])
    }
}
