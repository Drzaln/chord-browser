import BrowserCore
import BrowserEngine
import BrowserTestSupport
import Foundation
import Testing

@testable import BrowserStore

@Suite("Find in page")
@MainActor
struct FindTests {

    private func makeStore() async -> (TabStore, FakeWebEngine) {
        let engine = FakeWebEngine()
        let store = TabStore(
            engine: engine,
            repository: FakeTabRepository(stored: [TabBuilder().url("https://a.example").build()]),
            clock: FixedClock()
        )
        // A store has no Space until it restores, and `newTab` needs one.
        await store.restore()
        store.select(store.tabs[0].id)
        return (store, engine)
    }

    /// The pane, not the tab. In a split, Cmd+F means the one you are looking
    /// at — searching all of them would scroll panes the user is not reading.
    @Test("Searches the focused pane of a split, not the first one")
    func searchesTheFocusedPane() async {
        let (store, engine) = await makeStore()
        let tabID = store.selectedTabID!
        store.split(tabID)

        let focused = store.selectedTab!.focusedPaneID
        let other = store.selectedTab!.panes.first { $0.id != focused }!.id

        store.findText = "hello"
        store.findNext()
        await store.waitForFind()

        #expect(engine.findQueries.map(\.paneID) == [focused])
        #expect(engine.findQueries.map(\.paneID).contains(other) == false)
    }

    @Test("A hit and a miss are reported apart")
    func reportsWhetherItMatched() async {
        let (store, engine) = await makeStore()
        engine.findMatches = ["present"]

        store.findText = "present"
        store.findNext()
        await store.waitForFind()
        #expect(store.findFoundMatch == true)

        store.findText = "absent"
        store.findNext()
        await store.waitForFind()
        #expect(store.findFoundMatch == false)
    }

    /// Emptying the field is not a failed search. Without this the bar flashes
    /// "Not found" on every backspace as the query is deleted.
    @Test("An emptied field reports nothing rather than 'not found'")
    func emptyQueryIsNotAMiss() async {
        let (store, engine) = await makeStore()
        engine.findMatches = ["x"]

        store.findText = "x"
        store.findNext()
        await store.waitForFind()
        #expect(store.findFoundMatch == true)

        store.findText = ""
        store.findNext()
        #expect(store.findFoundMatch == nil)
        #expect(engine.findQueries.count == 1, "an empty query never reaches the engine")
    }

    /// Typing is faster than WebKit answers, so the search for a prefix is
    /// still outstanding when the next keystroke starts its own. The superseded
    /// one must not report its answer.
    ///
    /// Verified to fail without the cancellation guard in `runFind` — an
    /// earlier version of this test also passed *with* the guard removed,
    /// which is the trap: it was asserting on a redundant text comparison
    /// rather than on the thing that actually does the work.
    @Test("A superseded query does not report its answer")
    func supersededQueryIsDiscarded() async {
        let (store, engine) = await makeStore()
        engine.findMatches = ["ab"]
        // The superseded query is the *slow* one, so it tries to report after
        // the current one already has. A synchronous fake cannot stage this:
        // queries would finish in order and the guard would never be exercised.
        engine.findDelays = ["a": .milliseconds(80)]

        store.findText = "a"       // would miss, and answers last
        store.findNext()
        let superseded = store.primaryWindow.findTask
        store.findText = "ab"      // hits, issued before the first returns
        store.findNext()

        await store.waitForFind()
        await superseded?.value

        #expect(store.findFoundMatch == true, "the answer belongs to the current text")
    }

    @Test("Dismissing the bar clears the page's highlight")
    func dismissingClearsTheHighlight() async {
        let (store, engine) = await makeStore()
        let paneID = store.selectedTab!.focusedPaneID

        store.showFindBar()
        store.findText = "anything"
        store.hideFindBar()

        #expect(store.isFindBarVisible == false)
        #expect(engine.clearedFindPanes == [paneID])
    }
}

extension TabStore {
    /// Awaits the primary window's in-flight find, so tests assert on a settled
    /// result rather than polling.
    func waitForFind() async {
        await primaryWindow.findTask?.value
    }
}
