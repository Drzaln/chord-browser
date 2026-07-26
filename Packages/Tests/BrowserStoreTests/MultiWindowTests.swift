import BrowserCore
import BrowserEngine
import BrowserTestSupport
import Foundation
import Testing

@testable import BrowserStore

/// Two windows over one store.
///
/// The shape was checked against Arc, which this replicates: the Space *list* is
/// shared (a Space made in one window appears in the other), while the active
/// Space, the selection, and the sidebar are per-window.
@Suite("Multiple windows")
@MainActor
struct MultiWindowTests {

    private func makeStore(stored: [Tab] = []) async -> TabStore {
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: FakeTabRepository(stored: stored),
            clock: FixedClock()
        )
        await store.restore()
        return store
    }

    /// The first scene gets the primary; every one after it gets its own.
    @Test("Each window claims its own state, the first being the primary")
    func claimVendsDistinctWindows() async {
        let store = await makeStore()

        let first = store.claimWindow()
        let second = store.claimWindow()

        #expect(first === store.primaryWindow)
        #expect(second !== first)
        #expect(store.windows.count == 2)

        store.unregister(second)
        #expect(store.windows.count == 1, "a closed window stops being reconciled")
    }

    @Test("Two windows can sit in different Spaces at once")
    func windowsHoldDifferentSpaces() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://a.example").build()
        ])
        let first = try! #require(store.activeSpace(in: store.primaryWindow))
        let second = store.addSpace()

        let windowA = store.claimWindow()
        let windowB = store.claimWindow()

        store.selectSpace(first.id, in: windowA)
        store.selectSpace(second.id, in: windowB)

        #expect(store.activeSpace(in: windowA)?.id == first.id)
        #expect(
            store.activeSpace(in: windowB)?.id == second.id,
            "switching Space in one window must not move the other"
        )
    }

    /// Cmd+1…9 in Arc moves only the focused window.
    @Test("Selecting a Space by index moves only that window")
    func selectSpaceByIndexIsPerWindow() async {
        let store = await makeStore()
        store.addSpace()
        let windowA = store.claimWindow()
        let windowB = store.claimWindow()

        // `addSpace` puts the window that made it on the new Space, so park both
        // on the first one — otherwise the switch below is a no-op and the test
        // passes without moving anything.
        let first = store.spaces.sorted { $0.sortIndex < $1.sortIndex }[0]
        store.selectSpace(first.id, in: windowA)
        store.selectSpace(first.id, in: windowB)
        #expect(store.activeSpace(in: windowA)?.id == first.id)

        store.selectSpace(atIndex: 1, in: windowA)

        #expect(store.activeSpace(in: windowA)?.id != first.id, "the focused window moves")
        #expect(store.activeSpace(in: windowB)?.id == first.id, "the other stays put")
    }

    @Test("A new tab opens in the window that asked for it")
    func newTabLandsInItsOwnWindow() async {
        let store = await makeStore()
        let windowA = store.claimWindow()
        let windowB = store.claimWindow()
        let wasShowing = windowA.selectedTabID

        store.newTab(url: URL(string: "https://new.example")!, in: windowB)

        #expect(store.selectedTab(in: windowB)?.focusedPane.url.host() == "new.example")
        #expect(windowA.selectedTabID == wasShowing, "the other window does not move")
    }

    /// The reconciliation rule: the window that closes picks its neighbour with
    /// intent; the others only need to stop pointing at something gone.
    @Test("Closing a tab another window is showing re-points that window")
    func closingRepointsOtherWindows() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://one.example").build(),
            TabBuilder().url("https://two.example").build(),
        ])
        let windowA = store.claimWindow()
        let windowB = store.claimWindow()

        let shared = try! #require(store.tabs.first { $0.focusedPane.url.host() == "two.example" })
        store.select(shared.id, in: windowA)
        store.select(shared.id, in: windowB)

        store.closeTab(shared.id, in: windowA)

        #expect(!store.tabs.contains { $0.id == shared.id })
        #expect(windowB.selectedTabID != shared.id, "window B must not show a closed tab")
        let survivor = try! #require(windowB.selectedTabID)
        #expect(store.tabs.contains { $0.id == survivor }, "and what it shows must exist")
    }

    /// The failure this guards against is the ugly one: a tab visible in window
    /// B being archived out from under the user because window A last touched it
    /// an hour ago.
    @Test("A tab shown in another window is never swept")
    func sweepSkipsTabsVisibleElsewhere() async {
        // Both tabs were last touched long before "now", so the sweep would take
        // them on idleness alone. `FixedClock` is a value type, so the age comes
        // from backdating the tabs rather than advancing the clock.
        let stale = Date(timeIntervalSince1970: 1_700_000_000)
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: FakeTabRepository(stored: [
                TabBuilder().url("https://idle.example").lastAccessed(stale).build(),
                TabBuilder().url("https://other.example").lastAccessed(stale).build(),
            ]),
            clock: FixedClock(now: stale.addingTimeInterval(3_600))
        )
        await store.restore()

        let windowA = store.claimWindow()
        let windowB = store.claimWindow()

        let idle = try! #require(store.tabs.first { $0.focusedPane.url.host() == "idle.example" })
        let other = try! #require(store.tabs.first { $0.focusedPane.url.host() == "other.example" })

        // Window A looks away; window B keeps it on screen.
        store.select(other.id, in: windowA)
        store.select(idle.id, in: windowB)

        store.idleWindow = .after(60)
        await store.sweepNow()

        #expect(
            store.tabs.contains { $0.id == idle.id },
            "it is on screen in window B, so it is not idle"
        )
    }

    @Test("Deleting a Space re-homes the windows that were in it")
    func deletingASpaceRehomesItsWindows() async {
        let store = await makeStore()
        let doomed = store.addSpace()
        let windowB = store.claimWindow()
        _ = store.claimWindow()

        store.selectSpace(doomed.id, in: windowB)
        #expect(store.activeSpace(in: windowB)?.id == doomed.id)

        await store.deleteSpace(doomed.id, in: store.primaryWindow)

        #expect(!store.spaces.contains { $0.id == doomed.id })
        let landed = try! #require(store.activeSpace(in: windowB))
        #expect(store.spaces.contains { $0.id == landed.id }, "re-homed to a Space that exists")
    }

    @Test("Find state is per-window")
    func findIsPerWindow() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://a.example").build()
        ])
        let windowA = store.claimWindow()
        let windowB = store.claimWindow()

        store.showFindBar(in: windowA)
        windowA.findText = "needle"

        #expect(windowA.isFindBarVisible)
        #expect(!windowB.isFindBarVisible, "opening find in one window does not open it in the other")
        #expect(windowB.findText.isEmpty)
    }
}
