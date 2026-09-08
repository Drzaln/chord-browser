import ChordCore
import ChordEngine
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

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

        // In-memory, not `UserDefaults`: this state persists on write, and a
        // test has no business editing the real profile's sidebar.
        let window = WindowState(defaults: InMemoryPreferenceStore())

        #expect(!window.isPinnedSectionCollapsed(inSpace: store.activeSpace?.id))
        window.togglePinnedSectionCollapsed(inSpace: store.activeSpace?.id)
        #expect(window.isPinnedSectionCollapsed(inSpace: store.activeSpace?.id))

        store.selectSpace(second.id)
        #expect(
            !window.isPinnedSectionCollapsed(inSpace: store.activeSpace?.id),
            "collapse is scoped to the Space it was set in"
        )

        store.selectSpace(first.id)
        #expect(
            window.isPinnedSectionCollapsed(inSpace: store.activeSpace?.id),
            "the first Space stays collapsed"
        )
    }

    /// Two windows in the *same* Space disagree about the Pinned section —
    /// verified against Arc, where sidebar state is per-window.
    @Test("The Pinned collapse is per-window, not shared")
    func pinnedSectionCollapseIsPerWindow() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://pin.example").bookmarked(order: 0).build()
        ])
        let spaceID = try! #require(store.activeSpace).id

        // A store each: what is under test is that the *in-memory* state does
        // not bleed between windows, and sharing one would let A's write load
        // into B and hide exactly that.
        let windowA = WindowState(defaults: InMemoryPreferenceStore())
        let windowB = WindowState(defaults: InMemoryPreferenceStore())

        windowA.togglePinnedSectionCollapsed(inSpace: spaceID)

        #expect(windowA.isPinnedSectionCollapsed(inSpace: spaceID))
        #expect(
            !windowB.isPinnedSectionCollapsed(inSpace: spaceID),
            "collapsing in one window must not collapse the other"
        )
    }

    /// The sidebar is per-window too, and a new window seeds from the persisted
    /// value rather than starting at the built-in default.
    @Test("A new window inherits the last-used sidebar, then owns it")
    func newWindowInheritsSidebarThenDiverges() {
        // One store, two windows — the real app's shape, where every window
        // persists to the same defaults.
        let defaults = InMemoryPreferenceStore()

        let windowA = WindowState(defaults: defaults)
        windowA.sidebarWidth = 320
        windowA.isSidebarCollapsed = true

        let windowB = WindowState(defaults: defaults)
        #expect(windowB.sidebarWidth == 320, "a new window opens like the last one")
        #expect(windowB.isSidebarCollapsed)

        windowB.sidebarWidth = 200
        #expect(windowA.sidebarWidth == 320, "resizing one window must not resize the other")
    }

    @Test("Closing a loose tab returns to the loose tab that was active before it")
    func closingLooseTabReturnsToPreviouslyActive() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://github.example").pinned(order: 0).build(),
            TabBuilder().url("https://facebook.example").build(),
            TabBuilder().url("https://twitter.example").ephemeral(order: 1).build(),
        ])
        let facebook = try! #require(store.unpinnedTabs.first { $0.focusedPane.url.host() == "facebook.example" })
        let twitter = try! #require(store.unpinnedTabs.first { $0.focusedPane.url.host() == "twitter.example" })
        store.select(facebook.id)
        store.select(twitter.id)

        store.closeTab(twitter.id)

        #expect(store.selectedTabID == facebook.id, "the previously active loose tab wins")
    }

    @Test("Closing a loose tab with no history still picks the loose tab to its right")
    func closingLooseTabWithoutHistoryPicksItsRightNeighbour() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://github.example").pinned(order: 0).build(),
            TabBuilder().url("https://facebook.example").build(),
            TabBuilder().url("https://twitter.example").ephemeral(order: 1).build(),
            TabBuilder().url("https://last.example").ephemeral(order: 2).build(),
        ])
        let twitter = try! #require(store.unpinnedTabs.first { $0.focusedPane.url.host() == "twitter.example" })
        let last = try! #require(store.unpinnedTabs.first { $0.focusedPane.url.host() == "last.example" })
        // A direct selection (as a restored layout would) leaves no history.
        store.primaryWindow.selectedTabID = twitter.id

        store.closeTab(twitter.id)

        #expect(store.selectedTabID == last.id, "the tab that slides into the slot is the loose one to its right")
    }

    @Test("Closing a Pinned tab with no history leaves the window blank, not a section neighbour")
    func closingLastPinnedTabWithoutHistoryLeavesBlank() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://github.example").pinned(order: 0).build(),
            TabBuilder().url("https://pin.example").bookmarked(order: 0).build(),
            TabBuilder().url("https://other-pin.example").bookmarked(order: 1).build(),
            TabBuilder().url("https://loose.example").build(),
        ])
        var blankCloses = 0
        store.closeLeftBlankPresenter = { _ in blankCloses += 1 }
        let otherPin = try! #require(store.bookmarkedTabs.first { $0.focusedPane.url.host() == "other-pin.example" })
        // A direct selection (as a restored layout would) leaves no history.
        store.primaryWindow.selectedTabID = otherPin.id

        store.closeTab(otherPin.id)

        // Arc focuses the previously active tab; with no recency stack there is
        // nothing worth focusing (a section neighbour is an unloaded tile), so
        // the window goes blank — nothing rendered, no new tab — and the
        // command bar is offered.
        #expect(store.selectedTabID == nil, "the window goes blank with no selection")
        #expect(
            store.bookmarkedTabs.count == 2,
            "the Pinned tabs stay listed — closing only unloads them"
        )
        #expect(store.visibleTabs.count == 4, "no new tab was created")
        #expect(blankCloses == 1, "the blank close offers the command bar")
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

    @Test("Closing focused favourites follows Arc MRU and ends blank")
    func closingFocusedFavouriteGoesToPreviousActive() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://a.example").pinned(order: 0).build(),
            TabBuilder().url("https://b.example").pinned(order: 1).build(),
            TabBuilder().url("https://c.example").pinned(order: 2).build(),
        ])
        var blankCloses = 0
        store.closeLeftBlankPresenter = { _ in blankCloses += 1 }

        let a = try! #require(store.pinnedTabs.first { $0.focusedPane.url.host() == "a.example" })
        let b = try! #require(store.pinnedTabs.first { $0.focusedPane.url.host() == "b.example" })
        let c = try! #require(store.pinnedTabs.first { $0.focusedPane.url.host() == "c.example" })

        store.select(a.id)
        store.select(b.id)
        store.select(c.id)

        // Favourites are unloaded, not removed — all three stay in the grid.
        store.closeTab(c.id)
        #expect(store.selectedTabID == b.id, "closing c returns to the previous active b")
        #expect(store.pinnedTabs.count == 3, "favourites stay in the grid")

        // The unloaded c must not linger in the recency stack: closing b now
        // goes to a, not back to the just-unloaded c (Arc MRU).
        store.closeTab(b.id)
        #expect(store.selectedTabID == a.id, "closing b returns to a, not the unloaded c")
        #expect(store.pinnedTabs.count == 3, "b and c are still listed, just unloaded")
        #expect(blankCloses == 0, "no blank yet — there is still a live favourite to focus")

        // With every favourite already unloaded and the recency stack empty,
        // Arc shows nothing — no new tab, no dead tile. The window is blank
        // and the command bar is offered.
        store.closeTab(a.id)
        #expect(store.selectedTabID == nil, "closing the last live favourite leaves the window blank")
        #expect(store.pinnedTabs.count == 3, "all three tiles still listed after the closes")
        #expect(store.visibleTabs.count == 3, "no new tab was created")
        #expect(blankCloses == 1, "the blank close offers the command bar exactly once")
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
