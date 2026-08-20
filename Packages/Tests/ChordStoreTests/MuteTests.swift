import ChordCore
import ChordEngine
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

/// Per-tab mute (non-spec: user-requested).
@Suite("Per-tab mute")
@MainActor
struct MuteTests {

    private func makeStore(stored: [Tab]) async -> (TabStore, FakeWebEngine) {
        let engine = FakeWebEngine()
        let store = TabStore(
            engine: engine,
            repository: FakeTabRepository(stored: stored),
            clock: FixedClock()
        )
        await store.restore()
        return (store, engine)
    }

    @Test("Toggling mute flips the tab's state and tells the engine")
    func toggleMutes() async {
        let (store, engine) = await makeStore(stored: [
            TabBuilder().url("https://a.example").build()
        ])
        let tab = try! #require(store.visibleTabs.first)
        #expect(!store.isMuted(tab.id))

        store.toggleMute(tab.id)
        #expect(store.isMuted(tab.id))
        #expect(engine.mutedPanes.contains(tab.focusedPaneID))

        store.toggleMute(tab.id)
        #expect(!store.isMuted(tab.id))
        #expect(!engine.mutedPanes.contains(tab.focusedPaneID))
    }

    @Test("Muting a split silences every pane")
    func mutesAllPanes() async {
        let (store, engine) = await makeStore(stored: [
            TabBuilder().url("https://a.example").build()
        ])
        let tab = try! #require(store.visibleTabs.first)
        store.splitSelectedTab(url: URL(string: "https://b.example")!)

        store.toggleMute(tab.id)

        let panes = store.tabs.first { $0.id == tab.id }?.panes.map(\.id) ?? []
        #expect(panes.count == 2)
        for pane in panes { #expect(engine.mutedPanes.contains(pane)) }
    }
}
