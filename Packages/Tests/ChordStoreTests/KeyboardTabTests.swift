import ChordCore
import ChordEngine
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

/// Keyboard tab commands (non-spec: user-requested): reopen-closed-tab and
/// next/previous cycling.
@Suite("Keyboard tab commands")
@MainActor
struct KeyboardTabTests {

    private func makeStore(stored: [Tab]) async -> TabStore {
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: FakeTabRepository(stored: stored),
            clock: FixedClock()
        )
        await store.restore()
        return store
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

    // MARK: - Cycling

    @Test("Next tab advances and wraps past the end")
    func nextTabWraps() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://one.example").build(),
            TabBuilder().url("https://two.example").build(),
            TabBuilder().url("https://three.example").build(),
        ])
        let ordered = store.pinnedTabs + store.unpinnedTabs
        store.select(ordered[0].id)

        store.selectNextTab()
        #expect(store.selectedTabID == ordered[1].id)
        store.selectNextTab()
        #expect(store.selectedTabID == ordered[2].id)
        store.selectNextTab()
        #expect(store.selectedTabID == ordered[0].id, "wraps back to the first")
    }

    @Test("Previous tab steps back and wraps past the start")
    func previousTabWraps() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://one.example").build(),
            TabBuilder().url("https://two.example").build(),
        ])
        let ordered = store.pinnedTabs + store.unpinnedTabs
        store.select(ordered[0].id)

        store.selectPreviousTab()
        #expect(store.selectedTabID == ordered[1].id, "wraps to the last")
    }
}
