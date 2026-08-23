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

    @Test("Begin lists the Space's tabs most-recently-used first, excluding the current")
    func beginListsMRUOrder() async {
        let (store, a, b, c) = await makeMRUStore()
        let window = store.primaryWindow
        window.selectedTabID = c.id

        store.beginMRUSwitch()

        #expect(window.isMRUSessionPresented)
        #expect(window.mruTabIDs == [b.id, a.id])
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
        #expect(window.mruCursor == 0)
        store.selectNextTab()
        #expect(window.mruCursor == 1)
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
        #expect(window.mruCursor == 0, "wraps past the end back to the most recent")

        store.selectPreviousTab()
        #expect(window.mruCursor == 1, "wraps past the start to the last row")
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
        store.select(c.id)
        ticking.advance(1)
        store.select(b.id)
        ticking.advance(1)
        store.select(a.id)

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
        store.select(c.id)
        ticking.advance(1)
        store.select(b.id)
        ticking.advance(1)
        store.select(a.id)

        store.selectPreviousTab()
        #expect(store.selectedTabID == c.id, "jumps to the least recently used tab")
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
