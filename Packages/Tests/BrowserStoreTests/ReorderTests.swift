import BrowserCore
import BrowserEngine
import BrowserStore
import BrowserTestSupport
import Foundation
import Testing

@Suite("Sidebar reorder")
@MainActor
struct ReorderTests {

    private func makeStore(tabs: [Tab], spaces: [Space]) -> TabStore {
        let repository = FakeTabRepository(stored: tabs, spaces: spaces)
        return TabStore(
            engine: FakeWebEngine(),
            repository: repository,
            spaceRepository: repository,
            clock: FixedClock()
        )
    }

    private func ephemeral(_ url: String, space: UUID, order: Int) -> Tab {
        TabBuilder().url(url).space(space).ephemeral(order: order).build()
    }

    @Test("Reordering within the ephemeral section renumbers densely")
    func reorderWithinSection() async {
        let space = Space(name: "S", sortIndex: 0)
        let a = ephemeral("https://a.example", space: space.id, order: 0)
        let b = ephemeral("https://b.example", space: space.id, order: 1)
        let c = ephemeral("https://c.example", space: space.id, order: 2)
        let store = makeStore(tabs: [a, b, c], spaces: [space])
        await store.restore()

        // Move c to the front.
        store.reorderTab(c.id, toPinned: false, at: 0)

        #expect(store.unpinnedTabs.map { $0.panes[0].url.host() }
            == ["c.example", "a.example", "b.example"])
        #expect(store.unpinnedTabs.map(\.placement.order) == [0, 1, 2])
    }

    @Test("Dragging an ephemeral tab into the pinned section pins it")
    func crossSectionPins() async {
        let space = Space(name: "S", sortIndex: 0)
        let a = ephemeral("https://a.example", space: space.id, order: 0)
        let b = ephemeral("https://b.example", space: space.id, order: 1)
        let store = makeStore(tabs: [a, b], spaces: [space])
        await store.restore()

        store.reorderTab(b.id, toPinned: true, at: 0)

        #expect(store.pinnedTabs.map { $0.panes[0].url.host() } == ["b.example"])
        #expect(store.unpinnedTabs.map { $0.panes[0].url.host() } == ["a.example"])
    }

    @Test("Dragging a pinned tab into the ephemeral section unpins it")
    func crossSectionUnpins() async {
        let space = Space(name: "S", sortIndex: 0)
        let pinned = TabBuilder().url("https://p.example").space(space.id)
            .pinned(order: 0).build()
        let eph = ephemeral("https://e.example", space: space.id, order: 0)
        let store = makeStore(tabs: [pinned, eph], spaces: [space])
        await store.restore()

        store.reorderTab(pinned.id, toPinned: false, at: 1)

        #expect(store.pinnedTabs.isEmpty)
        #expect(store.unpinnedTabs.map { $0.panes[0].url.host() } == ["e.example", "p.example"])
    }

    @Test("An out-of-range index clamps to the section's ends")
    func indexClamps() async {
        let space = Space(name: "S", sortIndex: 0)
        let a = ephemeral("https://a.example", space: space.id, order: 0)
        let b = ephemeral("https://b.example", space: space.id, order: 1)
        let store = makeStore(tabs: [a, b], spaces: [space])
        await store.restore()

        store.reorderTab(a.id, toPinned: false, at: 99)
        #expect(store.unpinnedTabs.map { $0.panes[0].url.host() } == ["b.example", "a.example"])
    }

    @Test("Reordering one Space does not disturb another's tabs")
    func perSpaceIsolation() async {
        let s1 = Space(name: "One", sortIndex: 0)
        let s2 = Space(name: "Two", sortIndex: 1)
        let a = ephemeral("https://a.example", space: s1.id, order: 0)
        let b = ephemeral("https://b.example", space: s1.id, order: 1)
        let other = ephemeral("https://x.example", space: s2.id, order: 0)
        let store = makeStore(tabs: [a, b, other], spaces: [s1, s2])
        await store.restore()

        store.reorderTab(b.id, toPinned: false, at: 0)

        // s2's tab is untouched.
        let s2Tabs = store.tabs.filter { $0.spaceID == s2.id }
        #expect(s2Tabs.map(\.placement.order) == [0])
        #expect(s2Tabs.map { $0.panes[0].url.host() } == ["x.example"])
    }
}
