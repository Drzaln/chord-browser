import ChordCore
import ChordEngine
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

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

    /// A store restored from explicit Spaces, tabs, and saved window layouts —
    /// for the v9 layout-restore tests. Not `restore`d yet, so a caller can claim
    /// windows in whatever order it is exercising.
    private func makeLayoutStore(
        spaces: [Space], tabs: [Tab], layouts: [WindowLayout]
    ) -> TabStore {
        let repo = FakeTabRepository(stored: tabs, spaces: spaces)
        return TabStore(
            engine: FakeWebEngine(),
            repository: repo,
            spaceRepository: repo,
            windowLayoutRepository: FakeWindowLayoutRepository(stored: layouts),
            clock: FixedClock()
        )
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

    /// The one-window-per-tab invariant: a tab on screen in window A must not be
    /// named as the "previously active" pick when window B closes a tab — both
    /// windows pointing at one web view leaves one of them blank. The pick skips
    /// it and takes the slot neighbour instead.
    @Test("Closing does not return to a tab another window is showing")
    func closingSkipsATabAnotherWindowShows() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://x.example").build(),
            TabBuilder().url("https://z.example").build(),
            TabBuilder().url("https://y.example").build(),
        ])
        let windowA = store.claimWindow()
        let windowB = store.claimWindow()
        let x = try! #require(store.tabs.first { $0.focusedPane.url.host() == "x.example" })
        let z = try! #require(store.tabs.first { $0.focusedPane.url.host() == "z.example" })
        let y = try! #require(store.tabs.first { $0.focusedPane.url.host() == "y.example" })

        // B was on X once (so X is its most recent history entry), then A took
        // X over and B was re-pointed at Z.
        store.select(x.id, in: windowB)
        store.select(x.id, in: windowA)
        #expect(windowB.selectedTabID == z.id, "B reconciles off the tab A took")

        store.closeTab(z.id, in: windowB)

        #expect(windowA.selectedTabID == x.id, "A keeps showing X")
        #expect(
            windowB.selectedTabID == y.id,
            "B must not return to X (on screen in A), so it takes the slot neighbour"
        )
        #expect(windowB.selectedTabID != x.id)
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

    // MARK: - Cross-window tab drag

    /// Two windows in the same Space show the same list, so a drop between them
    /// is an ordinary reorder — no Space changes, so nothing to warn about.
    @Test("Dropping inside the same Space reorders without prompting")
    func dropInSameSpaceJustReorders() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://one.example").build(),
            TabBuilder().url("https://two.example").build(),
        ])
        let windowA = store.claimWindow()
        let windowB = store.claimWindow()
        let moving = try! #require(store.tabs.first { $0.focusedPane.url.host() == "two.example" })

        store.dropTab(moving.id, into: .ephemeral, at: 0, in: windowB)

        #expect(windowB.pendingTabMove == nil, "same Space is not a profile change")
        #expect(store.unpinnedTabs(in: windowB).first?.id == moving.id)
        #expect(windowB.selectedTabID == moving.id, "the window selects what was dropped on it")
        #expect(windowA.selectedTabID != nil)
    }

    /// The Arc behaviour: dragging a tab into a window sitting in another Space
    /// changes its Space, which swaps its cookie store — so it asks first.
    @Test("Dropping into a window in another Space asks before moving")
    func dropAcrossSpacesPromptsFirst() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://work.example").build()
        ])
        let windowA = store.claimWindow()
        let windowB = store.claimWindow()
        let home = try! #require(store.activeSpace(in: windowA))
        let other = store.addSpace(name: "Personal", in: windowB)

        let moving = try! #require(store.tabs.first)
        store.dropTab(moving.id, into: .ephemeral, at: 0, in: windowB)

        let pending = try! #require(windowB.pendingTabMove)
        #expect(pending.id == moving.id)
        #expect(pending.toSpaceName == "Personal")
        #expect(pending.fromSpaceName == home.name)
        #expect(
            store.tabs.first { $0.id == moving.id }?.spaceID == home.id,
            "nothing moves until the user says so"
        )
        #expect(store.visibleTabs(in: windowB).allSatisfy { $0.id != moving.id })
        _ = other
    }

    @Test("Dropping a tab onto another Space's button asks before moving")
    func dropOntoSpaceButtonPromptsFirst() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://work.example").build()
        ])
        let window = store.claimWindow()
        let home = try! #require(store.activeSpace(in: window))
        let personal = store.addSpace(name: "Personal", in: window)
        store.selectSpace(home.id, in: window)

        let moving = try! #require(store.tabs.first)
        store.dropTab(moving.id, ontoSpace: personal.id, in: window)

        let pending = try! #require(window.pendingTabMove)
        #expect(pending.destination == .space)
        #expect(pending.toSpaceName == "Personal")
        #expect(pending.fromSpaceName == home.name)
        #expect(
            store.tabs.first { $0.id == moving.id }?.spaceID == home.id,
            "nothing moves until the user says so"
        )
    }

    @Test("Confirming a Space-button drop moves the tab, keeping placement")
    func confirmingSpaceButtonDropMoves() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://work.example").build()
        ])
        let window = store.claimWindow()
        let home = try! #require(store.activeSpace(in: window))
        let personal = store.addSpace(name: "Personal", in: window)
        store.selectSpace(home.id, in: window)
        let moving = try! #require(store.tabs.first)

        store.dropTab(moving.id, ontoSpace: personal.id, in: window)
        store.confirmPendingTabMove(in: window)

        #expect(window.pendingTabMove == nil)
        #expect(store.tabs.first { $0.id == moving.id }?.spaceID == personal.id)
    }

    @Test("Dropping a tab onto its own Space's button does nothing")
    func dropOntoOwnSpaceButtonIsNoop() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://work.example").build()
        ])
        let window = store.claimWindow()
        let home = try! #require(store.activeSpace(in: window))
        let moving = try! #require(store.tabs.first)

        store.dropTab(moving.id, ontoSpace: home.id, in: window)

        #expect(window.pendingTabMove == nil, "it is already in that Space")
    }

    @Test("Confirming the move changes Space, places, and selects it")
    func confirmingTheMoveCompletesIt() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://work.example").build()
        ])
        let windowA = store.claimWindow()
        let windowB = store.claimWindow()
        let personal = store.addSpace(name: "Personal", in: windowB)
        let moving = try! #require(store.tabs.first { $0.focusedPane.url.host() == "work.example" })

        store.dropTab(moving.id, into: .ephemeral, at: 0, in: windowB)
        store.confirmPendingTabMove(in: windowB)

        #expect(windowB.pendingTabMove == nil)
        #expect(store.tabs.first { $0.id == moving.id }?.spaceID == personal.id)
        #expect(store.visibleTabs(in: windowB).contains { $0.id == moving.id })
        #expect(windowB.selectedTabID == moving.id)
        #expect(windowA.selectedTabID != moving.id, "it left the window it was dragged from")
    }

    @Test("Cancelling the move leaves the tab exactly where it was")
    func cancellingTheMoveChangesNothing() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://work.example").build()
        ])
        let windowA = store.claimWindow()
        let windowB = store.claimWindow()
        store.addSpace(name: "Personal", in: windowB)
        let moving = try! #require(store.tabs.first)
        let origin = moving.spaceID
        let wasSelected = windowA.selectedTabID

        store.dropTab(moving.id, into: .ephemeral, at: 0, in: windowB)
        store.cancelPendingTabMove(in: windowB)

        #expect(windowB.pendingTabMove == nil)
        #expect(store.tabs.first { $0.id == moving.id }?.spaceID == origin)
        #expect(windowA.selectedTabID == wasSelected)
    }

    /// A drop can also change tier, and crossing Spaces must not lose that.
    @Test("A cross-Space drop lands in the section it was dropped into")
    func crossSpaceDropKeepsItsSection() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://work.example").build()
        ])
        _ = store.claimWindow()
        let windowB = store.claimWindow()
        store.addSpace(name: "Personal", in: windowB)
        let moving = try! #require(store.tabs.first { $0.focusedPane.url.host() == "work.example" })

        store.dropTab(moving.id, into: .favourite, at: 0, in: windowB)
        store.confirmPendingTabMove(in: windowB)

        #expect(store.pinnedTabs(in: windowB).map(\.id) == [moving.id])
        #expect(store.unpinnedTabs(in: windowB).allSatisfy { $0.id != moving.id })
    }

    /// Newly reachable once a second window exists: before, the sidebar only
    /// ever showed one Space, so a drag could not carry a tab across one.
    @Test("Dragging into another window's split asks before crossing Spaces")
    func splitDropAcrossSpacesPromptsFirst() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://work.example").build()
        ])
        let windowA = store.claimWindow()
        let windowB = store.claimWindow()
        store.addSpace(name: "Personal", in: windowB)
        store.newTab(url: URL(string: "https://personal.example")!, in: windowB)

        let source = try! #require(store.tabs.first { $0.focusedPane.url.host() == "work.example" })
        let target = try! #require(store.selectedTab(in: windowB))

        store.split(target.id, byMoving: source.id, in: windowB)

        #expect(windowB.pendingTabMove != nil, "a cross-Space split is a profile change")
        #expect(store.tabs.contains { $0.id == source.id }, "nothing is destroyed until confirmed")
        #expect(store.tabs.first { $0.id == target.id }?.panes.count == 1)
        _ = windowA
    }

    @Test("Confirming a split drop merges the page into the target tab")
    func confirmingSplitDropMerges() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://work.example").build()
        ])
        _ = store.claimWindow()
        let windowB = store.claimWindow()
        store.addSpace(name: "Personal", in: windowB)
        store.newTab(url: URL(string: "https://personal.example")!, in: windowB)

        let source = try! #require(store.tabs.first { $0.focusedPane.url.host() == "work.example" })
        let target = try! #require(store.selectedTab(in: windowB))

        store.split(target.id, byMoving: source.id, in: windowB)
        store.confirmPendingTabMove(in: windowB)

        #expect(windowB.pendingTabMove == nil)
        #expect(!store.tabs.contains { $0.id == source.id }, "the source tab is consumed")
        let merged = try! #require(store.tabs.first { $0.id == target.id })
        #expect(merged.panes.count == 2)
        #expect(merged.panes.contains { $0.url.host() == "work.example" })
    }

    @Test("Cancelling a split drop leaves both tabs alone")
    func cancellingSplitDropChangesNothing() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://work.example").build()
        ])
        _ = store.claimWindow()
        let windowB = store.claimWindow()
        store.addSpace(name: "Personal", in: windowB)
        store.newTab(url: URL(string: "https://personal.example")!, in: windowB)

        let source = try! #require(store.tabs.first { $0.focusedPane.url.host() == "work.example" })
        let target = try! #require(store.selectedTab(in: windowB))

        store.split(target.id, byMoving: source.id, in: windowB)
        store.cancelPendingTabMove(in: windowB)

        #expect(store.tabs.contains { $0.id == source.id })
        #expect(store.tabs.first { $0.id == target.id }?.panes.count == 1)
    }

    /// Within one Space a split drop is unchanged — no prompt, immediate merge.
    @Test("A same-Space split drop still merges immediately")
    func sameSpaceSplitDropIsUnchanged() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://one.example").build(),
            TabBuilder().url("https://two.example").build(),
        ])
        let window = store.claimWindow()
        let source = try! #require(store.tabs.first { $0.focusedPane.url.host() == "two.example" })
        let target = try! #require(store.tabs.first { $0.focusedPane.url.host() == "one.example" })

        store.split(target.id, byMoving: source.id, in: window)

        #expect(window.pendingTabMove == nil, "no Space change, so nothing to warn about")
        #expect(store.tabs.first { $0.id == target.id }?.panes.count == 2)
    }

    // MARK: - One tab, one window (found by manual testing, 2026-07-27)

    /// A `WKWebView` is an `NSView` and an `NSView` has one superview, so a tab
    /// shown in two windows renders in whichever drew last and leaves the other
    /// **blank**. Every path that assigns a selection has to respect that.
    @Test("A new window never adopts a tab already on screen")
    func newWindowTakesItsOwnTab() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://one.example").build()
        ])
        let windowA = store.claimWindow()
        let shown = try! #require(windowA.selectedTabID)

        let windowB = store.claimWindow()

        #expect(windowB.selectedTabID != nil, "a new window must show something")
        #expect(
            windowB.selectedTabID != shown,
            "adopting the tab window A is showing would blank one of them"
        )
    }

    /// With only one tab in the Space there is nothing free to take, so the new
    /// window gets a tab of its own — which is what Cmd+N does anyway.
    @Test("A new window opens its own tab when every tab is taken")
    func newWindowOpensATabWhenNoneAreFree() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://only.example").build()
        ])
        _ = store.claimWindow()
        let before = store.tabs.count

        let windowB = store.claimWindow()

        #expect(store.tabs.count == before + 1)
        #expect(windowB.selectedTabID != nil)
    }

    @Test("Selecting a tab another window shows moves it, and re-points that one")
    func selectingATabHeldElsewhereHandsItOver() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://one.example").build(),
            TabBuilder().url("https://two.example").build(),
        ])
        let windowA = store.claimWindow()
        let windowB = store.claimWindow()
        let wanted = try! #require(windowA.selectedTabID)

        store.select(wanted, in: windowB)

        #expect(windowB.selectedTabID == wanted)
        #expect(windowA.selectedTabID != wanted, "window A gave it up")
        #expect(windowA.selectedTabID != nil, "and did not go blank")
    }

    /// No window may ever share a selection, whatever the sequence.
    @Test("No two windows ever hold the same selection")
    func selectionsAreNeverShared() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://a.example").build(),
            TabBuilder().url("https://b.example").build(),
            TabBuilder().url("https://c.example").build(),
        ])
        let windows = [store.claimWindow(), store.claimWindow(), store.claimWindow()]

        for window in windows {
            for tab in store.visibleTabs(in: window) {
                store.select(tab.id, in: window)
            }
        }

        let selections = windows.compactMap(\.selectedTabID)
        #expect(selections.count == windows.count, "every window shows something")
        #expect(Set(selections).count == selections.count, "and no two share a tab")
    }

    /// macOS restores a second scene at launch, which claims its state *before*
    /// `restore()` has loaded any Spaces or tabs — so it starts nil/nil. Nothing
    /// used to fix that afterwards, and the window stayed permanently empty.
    @Test("A window claimed before restore is repaired by it")
    func windowClaimedBeforeRestoreIsRepaired() async {
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: FakeTabRepository(stored: [
                TabBuilder().url("https://restored.example").build()
            ]),
            clock: FixedClock()
        )

        // Both scenes appear before the async restore finishes.
        let windowA = store.claimWindow()
        let windowB = store.claimWindow()
        #expect(windowB.activeSpaceID == nil, "nothing to point at yet")

        await store.restore()

        #expect(windowB.activeSpaceID != nil, "restore has to re-point it")
        #expect(windowB.selectedTabID != nil, "or the window renders empty forever")
        #expect(windowA.selectedTabID != windowB.selectedTabID)
    }

    /// `reconcile` used to read through a `?? spaces.first` fallback without ever
    /// writing it back, leaving the window with no Space of record.
    @Test("Reconcile assigns a Space rather than falling back to one")
    func reconcileAssignsTheSpace() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://a.example").build()
        ])
        let window = store.claimWindow()
        window.activeSpaceID = nil

        store.reconcile(window)

        #expect(window.activeSpaceID != nil)
        #expect(window.activeSpaceID == store.spaces.first?.id)
    }

    // MARK: - Window layout persistence (v9)

    @Test("Restore puts the primary on its saved Space and tab")
    func restoreAppliesPrimaryLayout() async {
        let spaceA = Space(name: "A", sortIndex: 0)
        let spaceB = Space(name: "B", sortIndex: 1)
        let tabA = TabBuilder().url("https://a.example").space(spaceA.id).build()
        let tabB = TabBuilder().url("https://b.example").space(spaceB.id).build()

        let store = makeLayoutStore(
            spaces: [spaceA, spaceB],
            tabs: [tabA, tabB],
            layouts: [WindowLayout(ordinal: 0, activeSpaceID: spaceB.id, selectedTabID: tabB.id)]
        )
        await store.restore()

        #expect(store.primaryWindow.activeSpaceID == spaceB.id, "not the first Space")
        #expect(store.primaryWindow.selectedTabID == tabB.id)
    }

    @Test("A window claiming after restore gets the next saved layout")
    func claimAfterRestoreAppliesNextLayout() async {
        let spaceA = Space(name: "A", sortIndex: 0)
        let spaceB = Space(name: "B", sortIndex: 1)
        let tabA = TabBuilder().url("https://a.example").space(spaceA.id).build()
        let tabB = TabBuilder().url("https://b.example").space(spaceB.id).build()

        let store = makeLayoutStore(
            spaces: [spaceA, spaceB],
            tabs: [tabA, tabB],
            layouts: [
                WindowLayout(ordinal: 0, activeSpaceID: spaceA.id, selectedTabID: tabA.id),
                WindowLayout(ordinal: 1, activeSpaceID: spaceB.id, selectedTabID: tabB.id),
            ]
        )
        _ = store.claimWindow()  // the primary scene claims first, as in the app
        await store.restore()
        let second = store.claimWindow()

        #expect(store.primaryWindow.activeSpaceID == spaceA.id)
        #expect(store.primaryWindow.selectedTabID == tabA.id)
        #expect(second !== store.primaryWindow, "a real second window")
        #expect(second.activeSpaceID == spaceB.id, "the second window's saved Space")
        #expect(second.selectedTabID == tabB.id)
    }

    @Test("A layout naming a tab the primary already shows never blanks the window")
    func layoutContestedTabFallsBackToReconcile() async {
        // Both layouts name the same Space and tab — a corrupt/stale layout. The
        // second window must not fight over one web view; it takes a free tab.
        let space = Space(name: "A", sortIndex: 0)
        let tab1 = TabBuilder().url("https://one.example").space(space.id).build()
        let tab2 = TabBuilder().url("https://two.example").space(space.id).build()

        let store = makeLayoutStore(
            spaces: [space],
            tabs: [tab1, tab2],
            layouts: [
                WindowLayout(ordinal: 0, activeSpaceID: space.id, selectedTabID: tab1.id),
                WindowLayout(ordinal: 1, activeSpaceID: space.id, selectedTabID: tab1.id),
            ]
        )
        _ = store.claimWindow()  // the primary scene claims first, as in the app
        await store.restore()
        let second = store.claimWindow()

        #expect(second !== store.primaryWindow, "a real second window")
        #expect(store.primaryWindow.selectedTabID == tab1.id)
        #expect(second.selectedTabID != nil, "or the window renders blank")
        #expect(
            second.selectedTabID != store.primaryWindow.selectedTabID,
            "one tab is shown in at most one window"
        )
    }

    @Test("A layout whose Space is gone reconciles instead of failing")
    func layoutStaleSpaceReconciles() async {
        let space = Space(name: "A", sortIndex: 0)
        let tab = TabBuilder().url("https://a.example").space(space.id).build()

        let store = makeLayoutStore(
            spaces: [space],
            tabs: [tab],
            layouts: [
                WindowLayout(ordinal: 0, activeSpaceID: UUID(), selectedTabID: UUID()),
            ]
        )
        await store.restore()

        #expect(store.primaryWindow.activeSpaceID == space.id, "re-homed to a real Space")
        #expect(store.primaryWindow.selectedTabID == tab.id)
    }

    @Test("Open windows' layouts are captured for saving in window order")
    func capturedLayoutsFollowWindowOrder() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://a.example").build()
        ])
        _ = store.claimWindow()  // the primary scene claims first, as in the app
        let second = store.claimWindow()
        let personal = store.addSpace(name: "Personal", in: second)
        store.selectSpace(personal.id, in: second)

        let layouts = store.captureWindowLayouts()
        #expect(layouts.count == 2)
        #expect(layouts[0].ordinal == 0)
        #expect(layouts[0].activeSpaceID == store.primaryWindow.activeSpaceID)
        #expect(layouts[1].ordinal == 1)
        #expect(layouts[1].activeSpaceID == personal.id)
        #expect(layouts[1].selectedTabID == second.selectedTabID)
    }

    /// App-opened URLs and a promoted Little Chord tab used to always hit the
    /// primary; they now follow the window the user last focused.
    @Test("focusedWindow tracks the last-focused window, falling back to primary")
    func focusedWindowTracksLastFocused() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://a.example").build()
        ])

        // Nothing focused yet: the primary is the sensible default (a URL that
        // opens the app cold has no window to inherit).
        #expect(store.focusedWindow === store.primaryWindow)

        let second = store.claimWindow()
        store.windowDidBecomeFocused(second)
        #expect(store.focusedWindow === second)

        // Focus moving back to the primary follows.
        store.windowDidBecomeFocused(store.primaryWindow)
        #expect(store.focusedWindow === store.primaryWindow)
    }

    /// The reference is weak: a focused window that closes must not be handed out
    /// (or kept alive), so focus falls back to the primary.
    @Test("A closed focused window falls back to the primary")
    func focusedWindowFallsBackWhenClosed() async {
        let store = await makeStore(stored: [
            TabBuilder().url("https://a.example").build()
        ])

        do {
            let second = store.claimWindow()
            store.windowDidBecomeFocused(second)
            #expect(store.focusedWindow === second)
            store.unregister(second)
        }
        // `second` is gone; the weak reference drops it and focus falls back.
        #expect(store.focusedWindow === store.primaryWindow)
    }
}
