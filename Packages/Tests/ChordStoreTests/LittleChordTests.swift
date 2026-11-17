import ChordCore
import ChordEngine
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

@Suite("Little Chord")
@MainActor
struct LittleChordTests {

    private func makeStore() -> (TabStore, FakeWebEngine) {
        let engine = FakeWebEngine()
        let store = TabStore(
            engine: engine, repository: FakeTabRepository(), clock: FixedClock()
        )
        return (store, engine)
    }

    private let link = URL(string: "https://example.com/from-another-app")!

    @Test("A panel pane is not a tab")
    func panelPaneIsNotATab() async {
        let (store, _) = makeStore()
        await store.restore()
        let before = store.tabs.count

        let pane = store.makeLittleChordPane(url: link)

        // Invisible to the sidebar, the sweep, and persistence — it is not in
        // `tabs` at all.
        #expect(store.tabs.count == before)
        #expect(!store.tabs.contains { $0.panes.contains { $0.id == pane.id } })
    }

    @Test("The panel renders immediately, without waiting on a disk read")
    func panelSurfaceIsNotWithheld() async {
        let (store, _) = makeStore()
        await store.restore()

        let pane = store.makeLittleChordPane(url: link)

        // Nothing is stored for a brand-new pane, so withholding its surface
        // would only cost a frame for a read that must come back empty.
        #expect(store.littleChordSurface(for: pane) != nil)
    }

    @Test("The panel uses the active Space")
    func panelUsesActiveSpace() async {
        let (store, engine) = makeStore()
        await store.restore()
        let pane = store.makeLittleChordPane(url: link)

        _ = store.littleChordSurface(for: pane)

        // 4.6's point: a link arrives already logged in to whatever the active
        // Space is logged in to.
        #expect(engine.spaceForPane[pane.id] == store.activeSpaceID)
    }

    @Test("A Peek panel surfaces in the Space it was clicked from, not the active one")
    func peekPanelUsesClickSpace() async {
        let (store, engine) = makeStore()
        await store.restore()

        // A favourite in another Space — the click's home, which is what the
        // preview must be logged into, not whatever Space is currently active.
        // `addSpace` makes its Space active, so add a second to push it back to
        // inactive: the surface must still use the explicit click Space.
        let clickSpace = store.addSpace(name: "Work")
        _ = store.addSpace(name: "Personal 2")

        let pane = store.makeLittleChordPane(url: link)
        _ = store.littleChordSurface(for: pane, in: clickSpace.id)

        #expect(engine.spaceForPane[pane.id] == clickSpace.id)
    }

    @Test("Promoting hands the panel's live page to the tab instead of reloading it")
    func promoteKeepsTheLiveView() async {
        let (store, engine) = makeStore()
        await store.restore()
        let before = store.tabs.count

        let pane = store.makeLittleChordPane(url: link)
        _ = store.littleChordSurface(for: pane)
        #expect(engine.hasLiveView(paneID: pane.id))

        let tabID = store.promoteLittleChord(pane)

        #expect(store.tabs.count == before + 1)
        #expect(store.selectedTabID == tabID)
        #expect(store.selectedTab?.focusedPane.url == link)
        // The tab is the panel's pane, still on the view the panel was showing:
        // a new pane would build a new view and load the page a second time.
        #expect(store.selectedTab?.focusedPaneID == pane.id)
        #expect(engine.hasLiveView(paneID: pane.id))
        #expect(engine.createdPanes == [pane.id])
    }

    @Test("A promoted tab keeps the title and icon the page reported in the panel")
    func promoteCarriesTitleAndFavicon() async {
        let (store, engine) = makeStore()
        await store.restore()

        let pane = store.makeLittleChordPane(url: link)
        _ = store.littleChordSurface(for: pane)
        // Reported while the pane was in no tab; with no reload after promoting,
        // the page will not report them again.
        engine.emit(PaneSnapshot(url: link, title: "From another app", isLoading: false), for: pane.id)
        let icon = Data([1, 2, 3])
        engine.emitFavicon(icon, for: pane.id)

        store.promoteLittleChord(pane)

        #expect(store.selectedTab?.focusedPane.title == "From another app")
        #expect(store.selectedTab?.focusedPane.faviconData == icon)
    }

    @Test("Promoting into a window on another Space builds a fresh view there")
    func promoteAcrossSpacesRebuilds() async {
        let (store, engine) = makeStore()
        await store.restore()

        let pane = store.makeLittleChordPane(url: link)
        _ = store.littleChordSurface(for: pane)
        // The window moves on to another Space while the panel is up. The
        // panel's view is bound to the first Space's data store, so it must not
        // follow the tab into this one.
        let other = store.addSpace(name: "Work")
        #expect(store.activeSpaceID == other.id)

        store.promoteLittleChord(pane)

        #expect(store.selectedTab?.spaceID == other.id)
        #expect(store.selectedTab?.focusedPaneID != pane.id)
        #expect(!engine.hasLiveView(paneID: pane.id))
    }

    @Test("Promoting keeps where you navigated to, not where you started")
    func promoteUsesCurrentURL() async {
        let (store, _) = makeStore()
        await store.restore()

        let pane = store.makeLittleChordPane(url: link)
        _ = store.littleChordSurface(for: pane)

        // Follow a link inside the panel before promoting.
        let followed = URL(string: "https://example.com/followed")!
        store.runtime(for: pane.id).apply(
            PaneSnapshot(url: followed, title: "Followed", isLoading: false)
        )

        store.promoteLittleChord(pane)

        #expect(store.selectedTab?.focusedPane.url == followed)
    }

    @Test("Dismissing leaves nothing behind")
    func dismissTearsDown() async {
        let (store, engine) = makeStore()
        await store.restore()
        let before = store.tabs.count

        let pane = store.makeLittleChordPane(url: link)
        _ = store.littleChordSurface(for: pane)

        store.discardLittleChord(pane)

        #expect(!engine.hasLiveView(paneID: pane.id))
        #expect(store.tabs.count == before)
    }

    @Test("Swipe-to-close on a Little Chord pane dismisses the panel")
    func swipeCloseDismissesLittleChord() async {
        let (store, engine) = makeStore()
        await store.restore()
        var dismissed = false
        store.littleChordDismisser = { dismissed = true }

        let pane = store.makeLittleChordPane(url: link)
        _ = store.littleChordSurface(for: pane)
        #expect(engine.hasLiveView(paneID: pane.id))

        store.paneRequestedSwipeClose(pane.id)

        #expect(!engine.hasLiveView(paneID: pane.id))
        #expect(dismissed)
    }
}
