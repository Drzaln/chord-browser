import ChordCore
import ChordEngine
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

/// Per-tab sleep timer (non-spec: user-requested).
@Suite("Per-tab sleep timer")
@MainActor
struct SleepTimerTests {

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

    @Test("Arming a timer arms the tab and tells the engine; cancelling undoes it")
    func armAndCancel() async {
        let (store, engine) = await makeStore(stored: [
            TabBuilder().url("https://a.example").build()
        ])
        let tab = try! #require(store.visibleTabs.first)
        #expect(!store.isSleepTimerArmed(tab.id))

        store.setSleepTimer(minutes: 30, tabID: tab.id)
        #expect(store.isSleepTimerArmed(tab.id))
        #expect(engine.sleepTimers[tab.focusedPaneID] != nil)

        store.cancelSleepTimer(tab.id)
        #expect(!store.isSleepTimerArmed(tab.id))
        #expect(engine.sleepTimers[tab.focusedPaneID] == nil)
    }

    @Test("Arming a timer on a split arms every pane")
    func armsAllPanes() async {
        let (store, engine) = await makeStore(stored: [
            TabBuilder().url("https://a.example").build()
        ])
        let tab = try! #require(store.visibleTabs.first)
        store.splitSelectedTab(url: URL(string: "https://b.example")!)

        store.setSleepTimer(minutes: 15, tabID: tab.id)

        let panes = store.tabs.first { $0.id == tab.id }?.panes.map(\.id) ?? []
        #expect(panes.count == 2)
        for pane in panes { #expect(engine.sleepTimers[pane] != nil) }
    }

    @Test("Re-arming replaces the tab's existing timer")
    func rearmReplaces() async {
        let (store, engine) = await makeStore(stored: [
            TabBuilder().url("https://a.example").build()
        ])
        let tab = try! #require(store.visibleTabs.first)

        store.setSleepTimer(minutes: 15, tabID: tab.id)
        let firstDeadline = engine.sleepTimers[tab.focusedPaneID]

        store.setSleepTimer(minutes: 60, tabID: tab.id)
        let secondDeadline = engine.sleepTimers[tab.focusedPaneID]

        #expect(secondDeadline != nil)
        #expect(secondDeadline != firstDeadline)
    }
}
