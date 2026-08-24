import ChordCore
import ChordEngine
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

/// Keyboard tab commands (non-spec: user-requested): reopen-closed-tab and the
/// Arc-style most-recently-used Ctrl+Tab switcher.
@Suite("Keyboard tab commands")
@MainActor
struct KeyboardTabTests {

    /// `FixedClock` is a value type and `TabStore` holds its clock for life, so
    /// a test that needs distinct `lastAccessedAt` times after the store is
    /// built uses one whose `now` can be moved.
    private final class TickingClock: Clock, @unchecked Sendable {
        private var value: Date
        init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { value = start }
        var now: Date { value }
        func advance(_ interval: TimeInterval) { value += interval }
    }

    private func makeStore(
        stored: [Tab], clock: any Clock = FixedClock()
    ) async -> TabStore {
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: FakeTabRepository(stored: stored),
            clock: clock
        )
        await store.restore()
        return store
    }

    /// Three tabs with strictly increasing `lastAccessedAt`, so MRU order is
    /// `c` (most recent) → `b` → `a`.
    private func makeMRUStore() async -> (store: TabStore, a: Tab, b: Tab, c: Tab) {
        let t0 = Date(timeIntervalSince1970: 0)
        let store = await makeStore(stored: [
            TabBuilder().url("https://a.example").lastAccessed(t0).build(),
            TabBuilder().url("https://b.example").lastAccessed(t0.addingTimeInterval(1)).build(),
            TabBuilder().url("https://c.example").lastAccessed(t0.addingTimeInterval(2)).build(),
        ])
        let a = try! #require(store.visibleTabs.first { $0.focusedPane.url.host() == "a.example" })
        let b = try! #require(store.visibleTabs.first { $0.focusedPane.url.host() == "b.example" })
        let c = try! #require(store.visibleTabs.first { $0.focusedPane.url.host() == "c.example" })
        // The switcher lists opened tabs only, so open all three: resolve their
        // (empty) stored state first so `surface(for:)` is not withheld.
        for tab in store.visibleTabs {
            store.markInteractionStateResolved(tab.focusedPaneID)
            _ = store.surface(for: tab)
        }
        return (store, a, b, c)
    }

    // MARK: - Reopen

    @Test("Reopening restores the last closed tab's URL")
    func reopenRestoresClosedTab() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://a.example").build(),
            TabBuilder().url("https://b.example").build(),
        ])
        let closing = try! #require(store.visibleTabs.first { $0.focusedPane.url.host() == "b.example" })

        store.closeTab(closing.id)
        #expect(store.visibleTabs.contains { $0.focusedPane.url.host() == "b.example" } == false)

        store.reopenLastClosedTab()
        #expect(store.visibleTabs.contains { $0.focusedPane.url.host() == "b.example" })
        #expect(store.selectedTab?.focusedPane.url.host() == "b.example")
    }

    @Test("Reopen is last-in-first-out across several closes")
    func reopenIsLIFO() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://a.example").build(),
            TabBuilder().url("https://b.example").build(),
            TabBuilder().url("https://c.example").build(),
        ])
        let a = try! #require(store.visibleTabs.first { $0.focusedPane.url.host() == "a.example" })
        let b = try! #require(store.visibleTabs.first { $0.focusedPane.url.host() == "b.example" })

        store.closeTab(a.id)
        store.closeTab(b.id)

        store.reopenLastClosedTab()
        #expect(store.selectedTab?.focusedPane.url.host() == "b.example")
        store.reopenLastClosedTab()
        #expect(store.selectedTab?.focusedPane.url.host() == "a.example")
    }

    @Test("Reopening a pinned tab restores it pinned")
    func reopenKeepsPinnedState() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://keep.example").pinned(order: 0).build(),
            TabBuilder().url("https://other.example").build(),
        ])
        let pinned = try! #require(store.pinnedTabs.first)

        store.closeTab(pinned.id)
        store.reopenLastClosedTab()

        #expect(store.pinnedTabs.contains { $0.focusedPane.url.host() == "keep.example" })
    }

    @Test("Reopen with nothing closed is a no-op")
    func reopenWithEmptyStackDoesNothing() async {
        let store = await makeStore(stored: [TabBuilder().url("https://a.example").build()])
        let before = store.visibleTabs.count
        store.reopenLastClosedTab()
        #expect(store.visibleTabs.count == before)
    }

    // MARK: - Most-recently-used switching (Ctrl+Tab)

    @Test("Begin lists the Space's tabs most-recently-used first, current included")
    func beginListsMRUOrder() async {
        let (store, a, b, c) = await makeMRUStore()
        let window = store.primaryWindow
        window.selectedTabID = c.id

        store.beginMRUSwitch()

        #expect(window.isMRUSessionPresented)
        #expect(window.mruTabIDs == [c.id, b.id, a.id], "current tab is shown, at the front")
    }

    @Test("The first Tab press skips the current tab and aims at the one before it")
    func firstPressSkipsCurrent() async {
        let (store, _, b, c) = await makeMRUStore()
        let window = store.primaryWindow
        window.selectedTabID = c.id

        store.beginMRUSwitch()
        store.selectNextTab()

        #expect(window.mruCursor == 1, "index 0 is the current tab, not a destination")
        store.commitMRUSwitch()
        #expect(store.selectedTabID == b.id)
    }

    @Test("A quick Ctrl+Tab commits the most recent tab")
    func quickCtrlTabSelectsMostRecent() async {
        let (store, _, b, c) = await makeMRUStore()
        let window = store.primaryWindow
        window.selectedTabID = c.id

        store.beginMRUSwitch()
        store.selectNextTab()
        store.commitMRUSwitch()

        #expect(store.selectedTabID == b.id)
        #expect(window.isMRUSessionPresented == false, "session is cleared on commit")
    }

    @Test("Holding Ctrl and pressing Tab walks down the list")
    func holdingStepsDownTheList() async {
        let (store, a, _, c) = await makeMRUStore()
        let window = store.primaryWindow
        window.selectedTabID = c.id

        store.beginMRUSwitch()
        store.selectNextTab()
        #expect(window.mruCursor == 1, "first press skips the current tab at index 0")
        store.selectNextTab()
        #expect(window.mruCursor == 2)
        store.commitMRUSwitch()

        #expect(store.selectedTabID == a.id, "walks past the most recent to the next one")
    }

    @Test("Stepping wraps at both ends of the list")
    func steppingWraps() async {
        let (store, _, _, c) = await makeMRUStore()
        let window = store.primaryWindow
        window.selectedTabID = c.id

        store.beginMRUSwitch()
        store.selectNextTab()
        store.selectNextTab()
        store.selectNextTab()
        #expect(window.mruCursor == 0, "wraps past the end back to the current tab")

        store.selectPreviousTab()
        #expect(window.mruCursor == 2, "wraps past the start to the last row")
    }

    @Test("Ctrl+Shift+Tab commits the least recent tab")
    func previousCommitsLeastRecent() async {
        let (store, a, _, c) = await makeMRUStore()
        let window = store.primaryWindow
        window.selectedTabID = c.id

        store.beginMRUSwitch()
        store.selectPreviousTab()
        store.commitMRUSwitch()

        #expect(store.selectedTabID == a.id)
    }

    @Test("A bare Ctrl tap selects nothing")
    func bareCtrlTapSelectsNothing() async {
        let (store, _, _, c) = await makeMRUStore()
        let window = store.primaryWindow
        window.selectedTabID = c.id

        store.beginMRUSwitch()
        store.commitMRUSwitch()

        #expect(store.selectedTabID == c.id, "no Tab was pressed, so nothing commits")
        #expect(window.isMRUSessionPresented == false)
    }

    @Test("Cancel abandons the session without selecting")
    func cancelAbandonsSession() async {
        let (store, _, _, c) = await makeMRUStore()
        let window = store.primaryWindow
        window.selectedTabID = c.id

        store.beginMRUSwitch()
        store.selectNextTab()
        store.cancelMRUSwitch()

        #expect(store.selectedTabID == c.id)
        #expect(window.isMRUSessionPresented == false)
        #expect(window.mruTabIDs.isEmpty)
    }

    @Test("A quick Ctrl+Tab switches without presenting the switcher")
    func quickSwitchDoesNotPresent() async {
        let (store, _, b, c) = await makeMRUStore()
        store.primaryWindow.selectedTabID = c.id

        store.selectNextTab()

        #expect(store.selectedTabID == b.id)
        #expect(store.primaryWindow.isMRUSessionPresented == false, "a quick tap must not flash the overlay")
        #expect(store.primaryWindow.mruTabIDs.isEmpty)
    }

    @Test("Without a session, Ctrl+Tab selects the most recent tab and toggles back")
    func steppingWithoutSessionSelectsMostRecent() async {
        let ticking = TickingClock()
        let store = await makeStore(
            stored: [
                TabBuilder().url("https://a.example").lastAccessed(Date(timeIntervalSince1970: 0)).build(),
                TabBuilder().url("https://b.example").lastAccessed(Date(timeIntervalSince1970: 1)).build(),
                TabBuilder().url("https://c.example").lastAccessed(Date(timeIntervalSince1970: 2)).build(),
            ],
            clock: ticking
        )
        // Activate in order so `lastAccessedAt` is deterministic: c → b → a.
let a = try! #require(store.visibleTabs.first { $0.focusedPane.url.host() == "a.example" })
        let b = try! #require(store.visibleTabs.first { $0.focusedPane.url.host() == "b.example" })
        let c = try! #require(store.visibleTabs.first { $0.focusedPane.url.host() == "c.example" })
        for tab in [a, b, c] {
            store.markInteractionStateResolved(tab.focusedPaneID)
            _ = store.surface(for: tab)
        }
        store.select(c.id)
        ticking.advance(1)
        store.select(b.id)
        ticking.advance(1)
        store.select(a.id)
        // The first Ctrl+Tab's commit touches `b`; advance so it strictly
        // outranks `a` (which was touched at the same tick as `select(a)`).
        ticking.advance(1)

        store.selectNextTab()
        #expect(store.selectedTabID == b.id, "jumps to the tab used just before")

        ticking.advance(1)
        store.selectNextTab()
        #expect(store.selectedTabID == a.id, "a second press toggles back to where it started")
    }

    @Test("Without a session, Ctrl+Shift+Tab selects the least recent tab")
    func previousWithoutSessionSelectsLeastRecent() async {
        let ticking = TickingClock()
        let store = await makeStore(
            stored: [
                TabBuilder().url("https://a.example").lastAccessed(Date(timeIntervalSince1970: 0)).build(),
                TabBuilder().url("https://b.example").lastAccessed(Date(timeIntervalSince1970: 1)).build(),
                TabBuilder().url("https://c.example").lastAccessed(Date(timeIntervalSince1970: 2)).build(),
            ],
            clock: ticking
        )
let a = try! #require(store.visibleTabs.first { $0.focusedPane.url.host() == "a.example" })
        let b = try! #require(store.visibleTabs.first { $0.focusedPane.url.host() == "b.example" })
        let c = try! #require(store.visibleTabs.first { $0.focusedPane.url.host() == "c.example" })
        for tab in [a, b, c] {
            store.markInteractionStateResolved(tab.focusedPaneID)
            _ = store.surface(for: tab)
        }
        store.select(c.id)
        ticking.advance(1)
        store.select(b.id)
        ticking.advance(1)
        store.select(a.id)

        store.selectPreviousTab()
        #expect(store.selectedTabID == c.id, "jumps to the least recently used tab")
    }

    @Test("Unopened tabs are not listed in the switcher")
    func unopenedTabsAreNotListed() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://a.example").lastAccessed(Date(timeIntervalSince1970: 0)).build(),
            TabBuilder().url("https://b.example").lastAccessed(Date(timeIntervalSince1970: 1)).build(),
            TabBuilder().url("https://c.example").lastAccessed(Date(timeIntervalSince1970: 2)).build(),
        ])
        let c = try! #require(store.visibleTabs.first { $0.focusedPane.url.host() == "c.example" })
        // Only `c` is opened (its surface was requested); `a` and `b` are
        // restored-but-never-shown sidebar tabs.
        store.markInteractionStateResolved(c.focusedPaneID)
        _ = store.surface(for: c)
        store.primaryWindow.selectedTabID = c.id

        store.beginMRUSwitch()

        #expect(store.primaryWindow.mruTabIDs == [c.id], "unopened tabs stay out of the switcher")
    }

    @Test("Closing a tab drops it from the switcher until it is shown again")
    func closedTabDropsOutUntilReopened() async {
        let (store, a, b, c) = await makeMRUStore()
        store.primaryWindow.selectedTabID = c.id

        store.closeTab(a.id)
        store.reopenLastClosedTab()  // a returns with the same pane id, but unshown

        store.beginMRUSwitch()

        #expect(!store.primaryWindow.mruTabIDs.contains(a.id), "closed-and-reopened but never shown stays out")
        #expect(store.primaryWindow.mruTabIDs == [c.id, b.id])
    }

    @Test("Closing a pinned tab unloads it and drops it from the switcher")
    func closedPinnedTabDropsFromSwitcher() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://a.example").bookmarked(order: 0, homeURL: "https://a.example")
                .lastAccessed(Date(timeIntervalSince1970: 0)).build(),
            TabBuilder().url("https://b.example").lastAccessed(Date(timeIntervalSince1970: 1)).build(),
        ])
        let a = try! #require(store.visibleTabs.first { $0.focusedPane.url.host() == "a.example" })
        let b = try! #require(store.visibleTabs.first { $0.focusedPane.url.host() == "b.example" })
        store.markInteractionStateResolved(a.focusedPaneID)
        store.markInteractionStateResolved(b.focusedPaneID)
        _ = store.surface(for: a)
        _ = store.surface(for: b)
        store.primaryWindow.selectedTabID = b.id

        // A bookmarked tab's close *unloads* it (the sidebar entry stays), so
        // it must stop being a Ctrl+Tab target even though it is still listed.
        store.closeTab(a.id)

        store.beginMRUSwitch()
        #expect(store.primaryWindow.mruTabIDs == [b.id], "a closed-but-still-listed pinned tab is not a target")

        store.selectNextTab()
        store.commitMRUSwitch()
        #expect(store.selectedTabID == b.id, "quick switch stays on b; the closed tab is not revived")
    }

    // MARK: - Page thumbnails

    @Test("A captured thumbnail is cached and served")
    func capturedThumbnailIsServed() async {
        let (store, _, _, c) = await makeMRUStore()

        store.paneDidCaptureThumbnail(c.id, data: Data([0x89, 0x50, 0x4E, 0x47]))

        #expect(store.thumbnail(for: c.id) != nil)
    }

    @Test("A failed capture keeps any existing thumbnail")
    func failedCaptureKeepsExisting() async {
        let (store, _, _, c) = await makeMRUStore()
        store.paneDidCaptureThumbnail(c.id, data: Data([0x89, 0x50, 0x4E, 0x47]))

        store.paneDidCaptureThumbnail(c.id, data: nil)

        #expect(store.thumbnail(for: c.id) != nil)
    }

    @Test("Refreshing a thumbnail asks the engine to capture")
    func refreshRequestsCapture() async {
        let engine = FakeWebEngine()
        let store = TabStore(
            engine: engine,
            repository: FakeTabRepository(stored: [TabBuilder().url("https://a.example").build()]),
            clock: FixedClock()
        )
        await store.restore()
        let tab = try! #require(store.selectedTab)

        let task = store.refreshThumbnail(for: tab.focusedPaneID)
        await task.value

        #expect(engine.thumbnailCaptures.contains(tab.focusedPaneID))
    }

    @Test("The thumbnail cache is LRU-capped")
    func thumbnailCacheIsLRUCapped() async {
        let (store, _, _, _) = await makeMRUStore()

        for _ in 0..<45 {
            store.paneDidCaptureThumbnail(UUID(), data: Data([0x89, 0x50, 0x4E, 0x47]))
        }

        #expect(store.thumbnails.count == 40, "older thumbnails are evicted once the cap is reached")
    }
}
