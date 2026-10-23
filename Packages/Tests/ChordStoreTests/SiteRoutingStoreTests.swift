import ChordCore
import ChordEngine
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

/// Routing rules (ADR 023): which Space an arriving link lands in, and the
/// precedence that keeps a rule from becoming a hijack.
@Suite("Site routing rules — store wiring")
@MainActor
struct SiteRoutingStoreTests {

    private func makeStore() -> (TabStore, FakeWebEngine, FakeTabRepository) {
        let engine = FakeWebEngine()
        let repository = FakeTabRepository()
        let store = TabStore(
            engine: engine,
            repository: repository,
            spaceRepository: repository,
            clock: FixedClock()
        )
        store.preferenceStore = InMemoryPreferenceStore()
        return (store, engine, repository)
    }

    /// Restores a store with a "Work" Space added and the window back on the
    /// original Space, returning both ids.
    private func storeWithWorkSpace() async -> (TabStore, UUID, UUID) {
        let (store, _, _) = makeStore()
        await store.restore()
        let personalID = store.spaces[0].id
        store.addSpace(name: "Work")
        let workID = store.spaces.first(where: { $0.name == "Work" })!.id
        store.selectSpace(personalID)
        return (store, personalID, workID)
    }

    @Test("A routed ⌘-click opens in the target Space without switching to it")
    func backgroundTabStaysInTheBackground() async {
        let (store, personalID, workID) = await storeWithWorkSpace()
        #expect(store.setRouteRule(pattern: "figma.com", spaceID: workID))
        let selectedBefore = store.selectedTabID
        let sourcePane = store.tabs.first { $0.spaceID == personalID }!.focusedPaneID

        store.paneRequestedBackgroundTab(
            url: URL(string: "https://www.figma.com/file/1")!, fromPane: sourcePane
        )

        // The gesture means "keep this", so the reading position wins.
        #expect(store.activeSpaceID == personalID)
        #expect(store.selectedTabID == selectedBefore)
        let routed = store.tabs.filter {
            $0.spaceID == workID && $0.panes.first?.url.host() == "www.figma.com"
        }
        #expect(routed.count == 1)
        #expect(routed.first?.panes.first?.url.host() == "www.figma.com")
    }

    @Test("A routed background tab revives a Space that was left blank")
    func routedTabResolvesBlankSpace() async {
        let (store, personalID, workID) = await storeWithWorkSpace()
        // A Space left blank (the user closed its last usable tab) shows the
        // new-tab bar. A tab arriving there must resolve that state, or the
        // routed tab exists but the Space still renders empty.
        store.primaryWindow.blankSpaceIDs.insert(workID)
        // Leaving a blank Space records "nothing selected" for it; mirror that,
        // or the switch back below would pick the stale tab by memory instead.
        store.lastSelectedTabBySpace[workID] = nil
        #expect(store.setRouteRule(pattern: "figma.com", spaceID: workID))

        store.paneRequestedBackgroundTab(
            url: URL(string: "https://figma.com/file/9")!,
            fromPane: store.tabs.first { $0.spaceID == personalID }!.focusedPaneID
        )
        #expect(!store.primaryWindow.blankSpaceIDs.contains(workID))

        store.selectSpace(workID)
        #expect(
            store.visibleTabs.contains { $0.panes.first?.url.host() == "figma.com" }
        )
    }

    @Test("An external launch routes and shows the Space it landed in")
    func externalLaunchSwitchesSpace() async {
        let (store, _, workID) = await storeWithWorkSpace()
        #expect(store.setRouteRule(pattern: "figma.com", spaceID: workID))

        var littleChordCalls = 0
        store.littleChordPresenter = { _ in littleChordCalls += 1 }

        store.openExternally(URL(string: "https://app.figma.com/file/2")!)

        #expect(littleChordCalls == 0)
        #expect(store.activeSpaceID == workID)
        #expect(store.selectedTab?.panes.first?.url.host() == "app.figma.com")
    }

    @Test("No rule leaves the external launch in Little Chord, as before")
    func unmatchedExternalGoesToLittleChord() async {
        let (store, _, _) = makeStore()
        await store.restore()
        var presented: URL?
        store.littleChordPresenter = { presented = $0 }

        let url = URL(string: "https://news.example/story")!
        store.openExternally(url)

        #expect(presented == url)
    }

    @Test("A private window ignores rules entirely")
    func privateWindowsIgnoreRules() async {
        let (store, _, workID) = await storeWithWorkSpace()
        #expect(store.setRouteRule(pattern: "figma.com", spaceID: workID))

        let privateWindow = WindowState(isPrivate: true)
        #expect(
            store.spaceID(
                forRouted: URL(string: "https://figma.com/")!, kind: .external,
                in: privateWindow
            ) == nil
        )
    }

    @Test("A rule can be limited to external launches")
    func newTabRoutingCanBeTurnedOff() async {
        let (store, _, workID) = await storeWithWorkSpace()
        #expect(
            store.setRouteRule(pattern: "figma.com", spaceID: workID, routesNewTabs: false)
        )
        let url = URL(string: "https://figma.com/")!

        #expect(store.spaceID(forRouted: url, kind: .newTab, in: store.primaryWindow) == nil)
        #expect(
            store.spaceID(forRouted: url, kind: .external, in: store.primaryWindow) == workID
        )
    }

    @Test("Deleting a Space deletes the rules that pointed at it")
    func deletingSpaceCleansRules() async {
        let (store, _, workID) = await storeWithWorkSpace()
        #expect(store.setRouteRule(pattern: "figma.com", spaceID: workID))

        await store.deleteSpace(workID, in: store.primaryWindow)

        #expect(store.routeRules.isEmpty)
    }

    @Test("A rule for a Space that does not exist is refused")
    func ruleNeedsARealSpace() async {
        let (store, _, _) = makeStore()
        await store.restore()
        #expect(store.setRouteRule(pattern: "figma.com", spaceID: UUID()) == false)
        #expect(store.routeRules.isEmpty)
    }

    @Test("Rules persist as preferences")
    func rulesPersist() async {
        let (store, _, _) = makeStore()
        await store.restore()
        let spaceID = store.spaces[0].id
        #expect(store.setRouteRule(pattern: "figma.com", spaceID: spaceID))
        let stored = Preferences.loadRouteRules(store.preferenceStore)
        #expect(stored.first?.pattern == "figma.com")
        #expect(stored.first?.spaceID == spaceID)
    }
}
