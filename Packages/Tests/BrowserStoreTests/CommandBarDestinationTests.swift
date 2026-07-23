import BrowserCore
import BrowserEngine
import BrowserTestSupport
import Foundation
import Testing

@testable import BrowserStore

/// Where a command bar result lands (4.4). `Cmd+Shift+D` opens the bar to fill
/// a *pane*, the same way `Cmd+T` opens it to fill a tab.
@Suite("Command bar destinations")
@MainActor
struct CommandBarDestinationTests {

    private func makeStore(stored: [Tab]) async -> TabStore {
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: FakeTabRepository(stored: stored),
            clock: FixedClock()
        )
        await store.restore()
        return store
    }

    private func navigate(to url: String) -> Suggestion {
        Suggestion(
            id: url, kind: .navigate(url: URL(string: url)!),
            title: url, subtitle: "", score: 1
        )
    }

    @Test("A result opened for a split becomes a pane, not a tab")
    func newPaneSplitsRatherThanOpeningATab() async {
        let store = await makeStore(stored: [TabBuilder().url("https://a.example").build()])
        store.select(store.tabs[0].id)

        store.activate(navigate(to: "https://b.example"), destination: .newPane)

        #expect(store.tabs.count == 1, "splitting must not add a tab")
        let panes = try! #require(store.selectedTab).panes
        #expect(panes.count == 2)
        #expect(panes.last?.url.host() == "b.example")
    }

    /// The tab is moved in, exactly as dragging it onto the pane would (4.5),
    /// so it never ends up existing twice.
    @Test("Choosing an open tab for a split moves it in rather than duplicating it")
    func openTabIsMovedIntoTheSplit() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://target.example").build(),
            TabBuilder().url("https://dragged.example").build(),
        ])
        let target = store.tabs[0]
        let dragged = store.tabs[1]
        store.select(target.id)

        store.activate(
            Suggestion(
                id: "t", kind: .openTab(tabID: dragged.id, spaceID: dragged.spaceID, spaceName: "dragged"),
                title: "dragged", subtitle: "", score: 1
            ),
            destination: .newPane
        )

        #expect(store.tabs.count == 1, "the chosen tab is moved, not copied")
        let panes = try! #require(store.selectedTab).panes
        #expect(panes.count == 2)
        #expect(panes.contains { $0.url.host() == "dragged.example" })
    }

    /// Cmd+Enter forces a new tab from any mode, splitting included.
    @Test("Forcing a new tab from split mode opens a tab, not a pane")
    func newTabDestinationStillOpensATab() async {
        let store = await makeStore(stored: [TabBuilder().url("https://a.example").build()])
        store.select(store.tabs[0].id)

        store.activate(navigate(to: "https://b.example"), destination: .newTab)

        #expect(store.tabs.count == 2)
        #expect(store.selectedTab?.panes.count == 1)
    }

    /// With nothing selected there is nothing to split, and one sensible
    /// landing place. Note an empty session still restores *into* a fresh tab,
    /// so this clears the selection rather than expecting no tabs at all.
    @Test("A split with no tab selected opens a tab instead of doing nothing")
    func splitWithoutASelectionFallsBackToATab() async {
        let store = await makeStore(stored: [])
        let before = store.tabs.count
        store.selectedTabID = nil

        store.activate(navigate(to: "https://b.example"), destination: .newPane)

        #expect(store.tabs.count == before + 1, "the page lands in a new tab")
        #expect(store.tabs.allSatisfy { $0.panes.count == 1 }, "nothing was split")
        #expect(store.tabs.contains { $0.focusedPane.url.host() == "b.example" })
    }
}
