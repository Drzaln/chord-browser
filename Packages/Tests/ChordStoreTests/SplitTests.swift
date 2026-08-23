import ChordCore
import ChordEngine
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

@Suite("Split view")
@MainActor
struct SplitTests {

    private func makeStore(
        stored: [Tab] = []
    ) -> (TabStore, FakeWebEngine, FakeTabRepository) {
        let engine = FakeWebEngine()
        let repository = FakeTabRepository(stored: stored)
        let store = TabStore(engine: engine, repository: repository, clock: FixedClock())
        return (store, engine, repository)
    }

    private func sum(_ tab: Tab) -> Double {
        tab.panes.map(\.widthFraction).reduce(0, +)
    }

    @Test("Splitting adds a pane and focuses it")
    func splitAddsPane() async {
        let (store, _, _) = makeStore()
        await store.restore()

        store.splitSelectedTab()

        let tab = try! #require(store.selectedTab)
        #expect(tab.panes.count == 2)
        // The new pane takes focus — you split in order to use the new side.
        #expect(tab.focusedPaneID == tab.panes[1].id)
        #expect(abs(sum(tab) - 1.0) < 0.000_001)
    }

    @Test("Focusing a pane's web view asks the engine for the keyboard")
    func focusWebViewAsksEngine() async {
        let (store, engine, _) = makeStore()
        await store.restore()
        let tab = try! #require(store.selectedTab)

        store.focusWebView(for: tab.focusedPaneID)

        #expect(engine.focusRequests.contains(tab.focusedPaneID))
    }

    @Test("Splitting stops at four panes")
    func splitCapsAtFour() async {
        let (store, _, _) = makeStore()
        await store.restore()

        for _ in 0..<10 { store.splitSelectedTab() }

        // 4.5 caps at four; the extra attempts must not replace a pane.
        #expect(store.selectedTab?.panes.count == SplitLayout.maxPanes)
        #expect(abs(sum(store.selectedTab!) - 1.0) < 0.000_001)
    }

    @Test("Closing a pane tears down its web view and keeps the tab")
    func closePaneKeepsTab() async {
        let (store, engine, _) = makeStore()
        await store.restore()
        store.splitSelectedTab()

        let tab = try! #require(store.selectedTab)
        let doomed = tab.panes[1].id
        // Give the pane a live view, so eviction is observable.
        _ = store.surface(for: tab.panes[1], in: tab)

        store.closePane(doomed)

        #expect(store.selectedTab?.panes.count == 1)
        #expect(store.tabs.count == 1)
        // A pane's web view belongs to that pane; nothing else reclaims it.
        #expect(!engine.hasLiveView(paneID: doomed))
    }

    @Test("Closing the focused pane moves focus to a survivor")
    func closingFocusedPaneMovesFocus() async {
        let (store, _, _) = makeStore()
        await store.restore()
        store.splitSelectedTab()

        let tab = try! #require(store.selectedTab)
        store.closePane(tab.focusedPaneID)

        let after = try! #require(store.selectedTab)
        #expect(after.panes.contains { $0.id == after.focusedPaneID })
    }

    @Test("Closing the last pane closes the tab")
    func closingLastPaneClosesTab() async {
        let (store, _, _) = makeStore(
            stored: [TabBuilder().url("https://a.example").build(),
                     TabBuilder().url("https://b.example").build()]
        )
        await store.restore()

        let victim = try! #require(store.tabs.first)
        store.closePane(victim.panes[0].id)

        #expect(!store.tabs.contains { $0.id == victim.id })
    }

    @Test("Swipe-to-close on one pane of a split closes only that pane")
    func swipeCloseOnSplitPaneKeepsTab() async {
        let (store, engine, _) = makeStore()
        await store.restore()
        store.splitSelectedTab()

        let tab = try! #require(store.selectedTab)
        let doomed = tab.panes[0].id
        _ = store.surface(for: tab.panes[0], in: tab)

        store.paneRequestedSwipeClose(doomed)

        #expect(store.tabs.count == 1, "the tab must survive a pane swipe-close")
        let after = try! #require(store.selectedTab)
        #expect(after.panes.count == 1)
        #expect(!after.panes.contains { $0.id == doomed })
        #expect(!engine.hasLiveView(paneID: doomed))
    }

    @Test("Swipe-to-close on a single-pane tab still closes the tab")
    func swipeCloseOnSinglePaneClosesTab() async {
        let (store, engine, tab) = await {
            let (store, engine, _) = makeStore()
            await store.restore()
            let tab = try! #require(store.selectedTab)
            return (store, engine, tab)
        }()

        store.paneRequestedSwipeClose(tab.focusedPane.id)

        #expect(!store.tabs.contains { $0.id == tab.id })
        #expect(engine.evictedPanes.contains(tab.focusedPane.id))
    }

    @Test("Cmd+W on a split closes only the focused pane, like Arc")
    func closeTabOnSplitClosesFocusedPane() async {
        let (store, engine, _) = makeStore()
        await store.restore()
        store.splitSelectedTab()

        let tab = try! #require(store.selectedTab)
        let focused = tab.focusedPaneID
        let survivor = tab.panes.first { $0.id != focused }!.id
        // Surface both panes so "survivor keeps its view" is actually asserted.
        for pane in tab.panes { _ = store.surface(for: pane, in: tab) }

        store.closeTab(tab.id)

        // The tab survives with just the other pane; the focused pane's view
        // is gone.
        let after = try! #require(store.selectedTab)
        #expect(store.tabs.count == 1)
        #expect(after.panes.count == 1)
        #expect(after.panes[0].id == survivor)
        #expect(!engine.hasLiveView(paneID: focused))
        #expect(engine.hasLiveView(paneID: survivor))
    }

    @Test("Cmd+Shift+T reopens a closed pane in its previous position, like Arc")
    func reopenClosedPaneRestoresPosition() async {
        let (store, _, _) = makeStore()
        await store.restore()
        store.splitSelectedTab()

        let tab = try! #require(store.selectedTab)
        let doomed = tab.panes[0].id  // the left pane
        store.closePane(doomed)

        #expect(store.selectedTab?.panes.count == 1)
        #expect(!store.selectedTab!.panes.contains { $0.id == doomed })

        store.reopenLastClosedTab(in: store.primaryWindow)

        let after = try! #require(store.selectedTab)
        #expect(after.panes.count == 2, "the closed pane comes back")
        #expect(after.panes[0].id == doomed, "reopened in its previous position")
        #expect(after.focusedPaneID == doomed)
    }

    @Test("Cmd+Shift+T reopens a closed right pane in its position too")
    func reopenClosedRightPaneRestoresPosition() async {
        let (store, _, _) = makeStore()
        await store.restore()
        store.splitSelectedTab()

        let tab = try! #require(store.selectedTab)
        let doomed = tab.panes[1].id  // the right pane
        store.closePane(doomed)

        store.reopenLastClosedTab(in: store.primaryWindow)

        let after = try! #require(store.selectedTab)
        #expect(after.panes.count == 2)
        #expect(after.panes[1].id == doomed, "reopened on the right")
    }

    @Test("Close pane then close tab: reopen restores tab first, then the pane")
    func reopenAfterClosePaneThenTabIsLIFO() async {
        let (store, _, _) = makeStore()
        await store.restore()
        store.splitSelectedTab()

        let tab = try! #require(store.selectedTab)
        let doomed = tab.panes[0].id
        store.closePane(doomed)  // push .pane(doomed)

        let survivor = try! #require(store.selectedTab)
        store.closeTab(survivor.id)  // push .tab(survivor)

        // First reopen pops the newer tab entry: the survivor tab comes back,
        // and since it keeps its id, the pane entry below it still has a home.
        store.reopenLastClosedTab(in: store.primaryWindow)
        let first = try! #require(store.tabs.first { $0.id == survivor.id })
        #expect(first.panes.count == 1)

        // Second reopen pops the pane entry and puts it back where it was.
        store.reopenLastClosedTab(in: store.primaryWindow)
        let restored = try! #require(store.tabs.first { $0.id == survivor.id })
        #expect(restored.panes.count == 2)
        #expect(restored.panes[0].id == doomed, "reopened in its previous position")
    }

    @Test("Survivors keep their relative widths when a pane closes")
    func closeKeepsProportions() async {
        let (store, _, _) = makeStore()
        await store.restore()
        store.splitSelectedTab()
        store.splitSelectedTab()

        var tab = try! #require(store.selectedTab)
        // Make the first pane clearly the widest, then remove the last.
        store.resizePanes(in: tab.id, dividerAfter: 0, by: 0.15)
        tab = try! #require(store.selectedTab)
        let ratioBefore = tab.panes[0].widthFraction / tab.panes[1].widthFraction

        store.closePane(tab.panes[2].id)

        let after = try! #require(store.selectedTab)
        #expect(abs(sum(after) - 1.0) < 0.000_001)
        #expect(abs(after.panes[0].widthFraction / after.panes[1].widthFraction - ratioBefore) < 0.01)
    }

    @Test("Focus follows the pane that was clicked")
    func focusPane() async {
        let (store, _, _) = makeStore()
        await store.restore()
        store.splitSelectedTab()

        let tab = try! #require(store.selectedTab)
        store.focusPane(tab.panes[0].id)

        #expect(store.selectedTab?.focusedPaneID == tab.panes[0].id)
    }

    @Test("A non-focused pane still gets its own surface")
    func nonFocusedPaneGetsSurface() async {
        // The bug M4 left behind: the surface gate was keyed on the tab's
        // focused pane, so with two panes on screen the non-focused one could
        // be built before its stored state had been read — loading the bare URL
        // and discarding the restore. Identical to the focused pane while a tab
        // only ever had one, which is why it survived M4.
        let (store, _, _) = makeStore()
        await store.restore()
        store.splitSelectedTab()

        let tab = try! #require(store.selectedTab)
        let unfocused = tab.panes[0]
        #expect(unfocused.id != tab.focusedPaneID)

        #expect(store.surface(for: unfocused, in: tab) != nil)
    }

    @Test("Dropping a sidebar tab onto another moves it in as a pane")
    func dropMovesTabIntoSplit() async {
        let (store, _, _) = makeStore(
            stored: [TabBuilder().url("https://target.example").build(),
                     TabBuilder().url("https://dragged.example").build()]
        )
        await store.restore()

        let target = try! #require(store.tabs.first { $0.panes[0].url.host() == "target.example" })
        let dragged = try! #require(store.tabs.first { $0.panes[0].url.host() == "dragged.example" })

        store.split(target.id, byMoving: dragged.id)

        // Moved, not copied: one row fewer, and the URL now lives in a pane.
        #expect(store.tabs.count == 1)
        let after = try! #require(store.tabs.first { $0.id == target.id })
        #expect(after.panes.count == 2)
        #expect(after.panes.map { $0.url.host() } == ["target.example", "dragged.example"])
        #expect(store.selectedTabID == target.id)
    }

    @Test("Dropping a tab onto itself does nothing")
    func dropOnSelfIsIgnored() async {
        let (store, _, _) = makeStore()
        await store.restore()

        let tab = try! #require(store.selectedTab)
        store.split(tab.id, byMoving: tab.id)

        #expect(store.selectedTab?.panes.count == 1)
        #expect(store.tabs.count == 1)
    }

    @Test("Dropping onto a full four-pane tab is refused, and keeps the dragged tab")
    func dropOntoFullTabIsRefused() async {
        let (store, _, _) = makeStore(
            stored: [TabBuilder().url("https://target.example").build(),
                     TabBuilder().url("https://dragged.example").build()]
        )
        await store.restore()

        let target = try! #require(store.tabs.first { $0.panes[0].url.host() == "target.example" })
        let dragged = try! #require(store.tabs.first { $0.panes[0].url.host() == "dragged.example" })
        store.select(target.id)
        for _ in 0..<3 { store.splitSelectedTab() }
        #expect(store.selectedTab?.panes.count == SplitLayout.maxPanes)

        store.split(target.id, byMoving: dragged.id)

        // Refusing must not eat the dragged tab — that would be data loss for
        // a gesture the user cannot undo.
        #expect(store.tabs.contains { $0.id == dragged.id })
        #expect(store.tabs.first { $0.id == target.id }?.panes.count == SplitLayout.maxPanes)
    }

    @Test("A pending pane withholds its own surface, even when the focused one is ready")
    func pendingPaneWithholdsItsOwnSurface() async {
        // This is the exact shape of the bug M4 left behind, made deterministic:
        // the gate has to be read for the pane being rendered, not the tab's
        // focused pane. Gating on the focused pane passes every test where both
        // panes resolve together — it only breaks when they disagree, which is
        // why it survived M4 and why the e2e version of this test cannot catch
        // it (there, resolution finishes before the surface is ever requested).
        let (store, _, _) = makeStore()
        await store.restore()
        store.splitSelectedTab()

        let tab = try! #require(store.selectedTab)
        let focused = try! #require(tab.pane(tab.focusedPaneID))
        let other = try! #require(tab.panes.first { $0.id != tab.focusedPaneID })

        store.stateResolution[focused.id] = .resolved
        store.stateResolution[other.id] = .pending

        #expect(store.surface(for: focused, in: tab) != nil)
        // With the old gate this returned a surface, built the web view from the
        // bare URL, and discarded whatever the blob was about to restore.
        #expect(store.surface(for: other, in: tab) == nil)
    }

    @Test("Every pane of a restored split gets its state resolved")
    func restoredSplitResolvesEveryPane() async {
        // Two panes, both with stored state. Showing the tab must resolve both,
        // not just whichever one happens to hold focus.
        let tab = TabBuilder()
            .url("https://left.example")
            .extraPane(url: "https://right.example")
            .build()

        let engine = FakeWebEngine()
        let repository = FakeTabRepository(stored: [tab])
        for pane in tab.panes {
            try? await repository.saveInteractionState(Data("state".utf8), paneID: pane.id)
        }
        let store = TabStore(engine: engine, repository: repository, clock: FixedClock())

        await store.restore()
        store.select(tab.id)

        let restored = try! #require(store.tabs.first { $0.id == tab.id })
        for pane in restored.panes {
            // Poll until resolution lands; it is an async disk read by design.
            for _ in 0..<50 where store.surface(for: pane, in: restored) == nil {
                try? await Task.sleep(for: .milliseconds(10))
            }
            #expect(store.surface(for: pane, in: restored) != nil, "pane \(pane.id) never resolved")
            #expect(engine.interactionState(for: pane.id) != nil, "pane \(pane.id) lost its state")
        }
    }
}
