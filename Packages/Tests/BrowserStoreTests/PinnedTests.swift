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

    @Test("Pinning a tab makes it a Pinned tab homed at its current URL")
    func bookmarkingCapturesHomeURL() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://youtube.example/watch").build()
        ])
        let tabID = try! #require(store.tabs.first).id

        store.setBookmarked(true, tabID: tabID)
        #expect(store.bookmarkedTabs.map(\.id) == [tabID])
        #expect(store.unpinnedTabs.isEmpty)
        #expect(store.tabs.first?.placement.homeURL?.absoluteString == "https://youtube.example/watch")

        store.setBookmarked(false, tabID: tabID)
        #expect(store.bookmarkedTabs.isEmpty)
        #expect(store.unpinnedTabs.map(\.id) == [tabID])
    }

    @Test("The three tiers are disjoint and cover every visible tab")
    func threeTiersPartitionTheSpace() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://fav.example").pinned(order: 0).build(),
            TabBuilder().url("https://pin.example").bookmarked(order: 0).build(),
            TabBuilder().url("https://loose.example").build(),
        ])

        #expect(store.pinnedTabs.map { $0.focusedPane.url.host() } == ["fav.example"])
        #expect(store.bookmarkedTabs.map { $0.focusedPane.url.host() } == ["pin.example"])
        #expect(store.unpinnedTabs.map { $0.focusedPane.url.host() } == ["loose.example"])
        #expect(
            store.pinnedTabs.count + store.bookmarkedTabs.count + store.unpinnedTabs.count
                == store.visibleTabs.count
        )
    }

    @Test("Returning a Pinned tab to its home navigates back to the pinned URL")
    func returnToPinnedHomeNavigatesBack() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://home.example").bookmarked(order: 0).build()
        ])
        let tab = try! #require(store.tabs.first)

        store.select(tab.id)
        store.navigate(to: URL(string: "https://home.example/deep/page")!)
        #expect(store.tabs.first?.focusedPane.url.absoluteString == "https://home.example/deep/page")

        store.returnToPinnedHome(tab.id)
        #expect(store.tabs.first?.focusedPane.url.absoluteString == "https://home.example")
    }

    @Test("Pinning to favourites records the home URL, and returning navigates back")
    func favouriteReturnsToHome() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://fav.example/home").build()
        ])
        let tabID = try! #require(store.tabs.first).id

        store.setPinned(true, tabID: tabID)
        #expect(store.tabs.first?.placement.homeURL?.absoluteString == "https://fav.example/home")

        store.select(tabID)
        store.navigate(to: URL(string: "https://fav.example/deep")!)
        store.returnToPinnedHome(tabID)
        #expect(store.tabs.first?.focusedPane.url.absoluteString == "https://fav.example/home")
    }

    @Test("Updating the pinned home swaps it for the current URL")
    func updatePinnedHomeUsesCurrentURL() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://pin.example/home").bookmarked(order: 0).build(),
            TabBuilder().url("https://fav.example/home").pinned(order: 0).build(),
        ])
        let pin = try! #require(store.bookmarkedTabs.first)
        let fav = try! #require(store.pinnedTabs.first)

        store.select(pin.id)
        store.navigate(to: URL(string: "https://pin.example/new")!)
        store.updatePinnedHome(pin.id)
        #expect(store.tabs.first { $0.id == pin.id }?.placement.homeURL?.absoluteString
            == "https://pin.example/new")

        store.select(fav.id)
        store.navigate(to: URL(string: "https://fav.example/new")!)
        store.updatePinnedHome(fav.id)
        #expect(store.tabs.first { $0.id == fav.id }?.placement.homeURL?.absoluteString
            == "https://fav.example/new")
    }

    @Test("The Pinned section collapses per-Space and remembers it")
    func pinnedSectionCollapseIsPerSpace() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://pin.example").bookmarked(order: 0).build()
        ])
        let first = try! #require(store.activeSpace)
        store.addSpace()
        let second = try! #require(store.spaces.first { $0.id != first.id })
        store.selectSpace(first.id)

        #expect(!store.isPinnedSectionCollapsed)
        store.togglePinnedSectionCollapsed()
        #expect(store.isPinnedSectionCollapsed)

        store.selectSpace(second.id)
        #expect(!store.isPinnedSectionCollapsed, "collapse is scoped to the Space it was set in")

        store.selectSpace(first.id)
        #expect(store.isPinnedSectionCollapsed, "the first Space stays collapsed")
    }

    @Test("Closing a favourite keeps it, and keeps its favicon")
    func closingAFavouriteKeepsIt() async {
        let icon = Data([0xAA, 0xBB, 0xCC])
        let store = await makeStore(stored: [
            TabBuilder().url("https://fav.example").favicon(icon).pinned(order: 0).build(),
            TabBuilder().url("https://loose.example").build(),
        ])
        let fav = try! #require(store.pinnedTabs.first)
        store.select(fav.id)

        store.closeTab(fav.id)

        #expect(store.pinnedTabs.map(\.id) == [fav.id], "the favourite is not removed")
        #expect(store.selectedTabID != fav.id, "selection moves off the closed favourite")
        #expect(
            store.pinnedTabs.first?.focusedPane.faviconData == icon,
            "the favicon survives the close"
        )
    }

    @Test("Closing a Pinned tab keeps it and returns it to its home URL")
    func closingAPinnedTabReturnsHome() async {
        let icon = Data([0x11, 0x22, 0x33])
        let store = await makeStore(stored: [
            TabBuilder().url("https://pin.example/home").favicon(icon).bookmarked(order: 0).build(),
            TabBuilder().url("https://loose.example").build(),
        ])
        let pin = try! #require(store.bookmarkedTabs.first)
        store.select(pin.id)
        store.navigate(to: URL(string: "https://pin.example/deep")!)

        store.closeTab(pin.id)

        #expect(store.bookmarkedTabs.map(\.id) == [pin.id], "the Pinned tab is not removed")
        #expect(
            store.bookmarkedTabs.first?.focusedPane.url.absoluteString == "https://pin.example/home",
            "closing resets it to the pinned home URL"
        )
        #expect(
            store.bookmarkedTabs.first?.focusedPane.faviconData == icon,
            "the favicon survives — home is the same origin"
        )
    }
}
