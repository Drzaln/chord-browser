import BrowserCore
import BrowserEngine
import BrowserStore
import BrowserTestSupport
import Foundation
import Testing

@Suite("Tab store")
@MainActor
struct TabStoreTests {

    private func makeStore(
        stored: [Tab] = []
    ) -> (TabStore, FakeWebEngine, FakeTabRepository) {
        let engine = FakeWebEngine()
        let repository = FakeTabRepository(stored: stored)
        let store = TabStore(engine: engine, repository: repository, clock: FixedClock())
        return (store, engine, repository)
    }

    @Test("An empty profile restores with one tab")
    func emptyRestoreOpensOneTab() async {
        let (store, _, _) = makeStore()
        await store.restore()

        #expect(store.tabs.count == 1)
        #expect(store.selectedTabID == store.tabs[0].id)
    }

    @Test("Restore does not create a web view for any tab")
    func restoreIsLazy() async {
        let stored = (0..<5).map { TabBuilder().url("https://\($0).example").build() }
        let (store, engine, _) = makeStore(stored: stored)

        await store.restore()

        // The single most important performance property of restore (6.2): the
        // model is populated, and not one content process has been spawned.
        #expect(store.tabs.count == 5)
        #expect(engine.liveViewCount() == 0)
    }

    @Test("Restore selects the most recently used tab")
    func restoreSelectsMostRecent() async {
        let old = TabBuilder()
            .url("https://old.example")
            .lastAccessed(Date(timeIntervalSince1970: 1_000))
            .build()
        let recent = TabBuilder()
            .url("https://recent.example")
            .lastAccessed(Date(timeIntervalSince1970: 9_000))
            .build()

        let (store, _, _) = makeStore(stored: [old, recent])
        await store.restore()

        #expect(store.selectedTabID == recent.id)
    }

    @Test("A failed load starts empty rather than refusing to launch")
    func failedLoadDegrades() async {
        let engine = FakeWebEngine()
        let repository = FakeTabRepository()
        await repository.setLoadError(CancellationError())
        let store = TabStore(engine: engine, repository: repository, clock: FixedClock())

        await store.restore()

        #expect(store.tabs.count == 1)  // recovered with a fresh tab
    }

    @Test("A web view is created only when a tab's surface is requested")
    func surfaceCreatesView() async {
        let (store, engine, _) = makeStore(stored: [TabBuilder().build()])
        await store.restore()
        #expect(engine.liveViewCount() == 0)

        // Since M4 the surface is withheld until the pane's stored
        // interactionState has been read, so the first request returns nil and
        // the view is built on the render that follows.
        for _ in 0..<400 where store.surface(for: store.tabs[0]) == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(engine.liveViewCount() == 1)
    }

    @Test("Closing a tab evicts its panes")
    func closeEvicts() async {
        let (store, engine, _) = makeStore(stored: [
            TabBuilder().url("https://a.example").build(),
            TabBuilder().url("https://b.example").build(),
        ])
        await store.restore()
        let victim = store.tabs[0]

        store.closeTab(victim.id)

        #expect(store.tabs.count == 1)
        #expect(engine.evictedPanes.contains(victim.panes[0].id))
    }

    @Test("Closing the last tab opens a fresh one")
    func closingLastTabReopens() async {
        let (store, _, _) = makeStore()
        await store.restore()

        store.closeTab(store.tabs[0].id)

        #expect(store.tabs.count == 1)
        #expect(store.selectedTabID == store.tabs[0].id)
    }

    @Test("Closing the selected tab selects a neighbour")
    func closingSelectedSelectsNeighbour() async {
        let (store, _, _) = makeStore(stored: [
            TabBuilder().url("https://a.example").build(),
            TabBuilder().url("https://b.example").build(),
            TabBuilder().url("https://c.example").build(),
        ])
        await store.restore()
        let middle = store.tabs[1]
        store.select(middle.id)

        store.closeTab(middle.id)

        #expect(store.selectedTabID == store.tabs[1].id)
        #expect(store.tabs.map { $0.panes[0].url.host() } == ["a.example", "c.example"])
    }

    @Test("A window.open request becomes a new tab hosting the popup's web view")
    func popupBecomesTab() async {
        let (store, engine, _) = makeStore()
        await store.restore()
        let before = store.tabs.count
        let popupPaneID = UUID()

        engine.emitPopupRequest(
            url: URL(string: "https://popup.example")!, popupPaneID: popupPaneID
        )

        #expect(store.tabs.count == before + 1)
        #expect(store.selectedTabID == store.tabs.last?.id, "the popup tab is selected")
        #expect(store.tabs.last?.focusedPaneID == popupPaneID)
        #expect(store.tabs.last?.focusedPane.url.host() == "popup.example")
    }

    @Test("window.close() on a popup closes its tab")
    func popupCloseClosesItsTab() async {
        let (store, engine, _) = makeStore(stored: [
            TabBuilder().url("https://shopee.example").build()
        ])
        await store.restore()
        let popupPaneID = UUID()

        engine.emitPopupRequest(
            url: URL(string: "https://accounts.google.example")!, popupPaneID: popupPaneID
        )
        let popupTabID = try! #require(store.tabs.last?.id)

        engine.emitPopupClosed(popupPaneID)

        #expect(store.tabs.allSatisfy { $0.id != popupTabID }, "the popup tab is gone")
        #expect(store.tabs.count == 1, "the opener tab survives")
    }

    @Test("Closing a popup that is already gone is a no-op")
    func popupCloseForMissingPaneDoesNothing() async {
        let (store, engine, _) = makeStore()
        await store.restore()
        let before = store.tabs

        engine.emitPopupClosed(UUID())

        #expect(store.tabs == before)
    }

    @Test("New tabs get increasing sidebar order")
    func newTabsAppend() async {
        let (store, _, _) = makeStore()
        await store.restore()
        store.newTab(url: URL(string: "https://second.example")!)
        store.newTab(url: URL(string: "https://third.example")!)

        #expect(store.tabs.map(\.placement.order) == [0, 1, 2])
    }
}

@Suite("Snapshot handling")
@MainActor
struct SnapshotTests {

    private func storeWithOneTab() async -> (TabStore, FakeWebEngine, Tab) {
        let engine = FakeWebEngine()
        let tab = TabBuilder().url("https://example.com").build()
        let store = TabStore(
            engine: engine,
            repository: FakeTabRepository(stored: [tab]),
            clock: FixedClock()
        )
        await store.restore()
        return (store, engine, store.tabs[0])
    }

    @Test("Volatile progress goes to the runtime, never to the model")
    func progressDoesNotTouchModel() async {
        let (store, engine, tab) = await storeWithOneTab()
        let before = store.tabs

        engine.emit(
            PaneSnapshot(
                url: tab.panes[0].url,
                title: "",
                isLoading: true,
                estimatedProgress: 0.4
            ),
            for: tab.focusedPaneID
        )

        // The tab array is untouched, so the sidebar does not redraw (6.4).
        #expect(store.tabs == before)
        #expect(store.runtime(for: tab.focusedPaneID).estimatedProgress == 0.4)
        #expect(store.runtime(for: tab.focusedPaneID).isLoading)
    }

    @Test("A new title updates the model")
    func titleUpdatesModel() async {
        let (store, engine, tab) = await storeWithOneTab()

        engine.emit(
            PaneSnapshot(url: tab.panes[0].url, title: "Example Domain"),
            for: tab.focusedPaneID
        )

        #expect(store.tabs[0].displayTitle == "Example Domain")
    }

    @Test("An empty title does not erase a good one")
    func emptyTitleIgnored() async {
        let (store, engine, tab) = await storeWithOneTab()
        engine.emit(PaneSnapshot(title: "Real Title"), for: tab.focusedPaneID)

        engine.emit(PaneSnapshot(title: ""), for: tab.focusedPaneID)

        #expect(store.tabs[0].displayTitle == "Real Title")
    }

    @Test("Navigation updates the pane's URL")
    func urlUpdatesModel() async {
        let (store, engine, tab) = await storeWithOneTab()

        engine.emit(
            PaneSnapshot(url: URL(string: "https://example.com/next")!),
            for: tab.focusedPaneID
        )

        #expect(store.tabs[0].panes[0].url.path() == "/next")
    }

    @Test("Favicon bytes reach the model")
    func faviconReachesModel() async {
        let (store, engine, tab) = await storeWithOneTab()
        let bytes = Data([0x01, 0x02])

        engine.emitFavicon(bytes, for: tab.focusedPaneID)

        #expect(store.tabs[0].panes[0].faviconData == bytes)
    }

    @Test("Navigation commands reach the engine")
    func commandsForward() async {
        let (store, engine, _) = await storeWithOneTab()

        store.goBack()
        store.goForward()
        store.reload()
        store.stopLoading()

        #expect(engine.backCount == 1)
        #expect(engine.forwardCount == 1)
        #expect(engine.reloadCount == 1)
        #expect(engine.stopCount == 1)
    }

    @Test("Navigating writes the URL through to the model immediately")
    func navigateUpdatesModel() async {
        let (store, engine, _) = await storeWithOneTab()
        let target = URL(string: "https://target.example")!

        store.navigate(to: target)

        #expect(engine.loadedURLs.last?.1 == target)
        #expect(store.tabs[0].panes[0].url == target)
    }
}
