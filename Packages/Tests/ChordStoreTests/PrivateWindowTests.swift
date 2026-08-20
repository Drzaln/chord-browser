import ChordCore
import ChordEngine
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

/// Private (incognito) windows — ⌘⇧N.
///
/// A private window is a window locked to a private `Space`, so almost every
/// assertion here is really "does the Space-scoped guard hold": nothing about
/// the window itself is ever written, and the tests that matter most are the
/// ones proving nothing reached a repository.
@Suite("Private windows")
@MainActor
struct PrivateWindowTests {

    private actor SpyHistory: HistoryRepository {
        private(set) var visits: [(url: URL, spaceID: UUID)] = []
        func recordVisit(url: URL, title: String, spaceID: UUID, at date: Date) async throws {
            visits.append((url, spaceID))
        }
        func recentHistory(inSpace spaceID: UUID, limit: Int) async throws -> [HistoryEntry] { [] }
        func deleteAllHistory() async throws {}
        func snapshot() -> [(url: URL, spaceID: UUID)] { visits }
    }

    private actor SpyArchive: ArchiveRepository {
        private(set) var archived: [ArchivedTab] = []
        func archive(_ tabs: [ArchivedTab]) async throws { archived += tabs }
        func archivedTabs() async throws -> [ArchivedTab] { archived }
        func count() -> Int { archived.count }
    }

    private func makeStore(
        stored: [Tab] = [], history: SpyHistory? = nil, archive: SpyArchive? = nil,
        clock: FixedClock = FixedClock()
    ) async -> (TabStore, FakeTabRepository, FakeWebEngine) {
        let repo = FakeTabRepository(stored: stored)
        let engine = FakeWebEngine()
        let store = TabStore(
            engine: engine,
            repository: repo,
            spaceRepository: repo,
            historyRepository: history,
            archiveRepository: archive,
            windowLayoutRepository: FakeWindowLayoutRepository(stored: []),
            clock: clock
        )
        await store.restore()
        return (store, repo, engine)
    }

    /// Opens a private window the way ⌘⇧N does: mark, then claim.
    private func openPrivateWindow(_ store: TabStore) -> WindowState {
        store.markNextWindowPrivate()
        return store.claimWindow()
    }

    // MARK: - Opening

    @Test("The marked window claims private, on a private Space of its own")
    func claimHonoursTheLatch() async {
        let (store, _, _) = await makeStore()
        _ = store.claimWindow()  // the primary

        let window = openPrivateWindow(store)

        #expect(window.isPrivate)
        let spaceID = try! #require(window.privateSpaceID)
        #expect(window.activeSpaceID == spaceID)
        #expect(store.spaces.first { $0.id == spaceID }?.isPrivate == true)
        #expect(store.selectedTab(in: window) != nil, "it opens on a tab of its own")
    }

    @Test("The latch is one-shot")
    func latchIsOneShot() async {
        let (store, _, _) = await makeStore()
        _ = store.claimWindow()

        let first = openPrivateWindow(store)
        let second = store.claimWindow()

        #expect(first.isPrivate)
        #expect(second.isPrivate == false, "the mark applies to exactly one window")
    }

    @Test("The primary window is never private")
    func primaryIsNeverPrivate() async {
        let (store, _, _) = await makeStore()
        // ⌘⇧N cannot be pressed before a window exists, but a stale latch must
        // not be able to turn the session's own window into a private one.
        store.markNextWindowPrivate()
        let primary = store.claimWindow()

        #expect(primary === store.primaryWindow)
        #expect(primary.isPrivate == false)
    }

    // MARK: - Nothing reaches disk

    @Test("A private Space is never written to the Space table")
    func privateSpaceIsNotPersisted() async {
        let (store, repo, _) = await makeStore()
        _ = store.claimWindow()
        _ = openPrivateWindow(store)

        await store.flushSaveAndWait()
        await store.persistSpaces()

        let saved = await repo.storedSpaces
        #expect(saved.contains { $0.isPrivate } == false)
        #expect(saved.count == store.visibleSpaces.count)
    }

    @Test("A private window's tabs are never saved")
    func privateTabsAreNotPersisted() async {
        let (store, repo, _) = await makeStore(stored: [
            TabBuilder().url("https://normal.example").build()
        ])
        _ = store.claimWindow()
        let window = openPrivateWindow(store)
        store.newTab(url: URL(string: "https://secret.example")!, in: window)

        await store.flushSaveAndWait()

        let saved = await repo.stored
        #expect(saved.contains { $0.focusedPane.url.host() == "secret.example" } == false)
        #expect(saved.contains { $0.focusedPane.url.host() == "normal.example" })
    }

    @Test("A layout naming a private Space is refused")
    func layoutCannotPointAWindowAtAPrivateSpace() async {
        let (store, _, _) = await makeStore(stored: [
            TabBuilder().url("https://normal.example").build()
        ])
        let primary = store.claimWindow()
        let window = openPrivateWindow(store)
        let privateSpaceID = try! #require(window.privateSpaceID)

        let applied = store.applyLayout(
            WindowLayout(ordinal: 0, activeSpaceID: privateSpaceID, selectedTabID: nil),
            to: primary
        )

        #expect(applied == false, "a stale layout must not steer a window into a private Space")
        #expect(store.isPrivate(spaceID: primary.activeSpaceID) == false)
    }

    @Test("A private window is left out of the saved layout, and the rest renumber")
    func privateWindowIsNotInTheLayout() async {
        let (store, _, _) = await makeStore(stored: [
            TabBuilder().url("https://normal.example").build()
        ])
        _ = store.claimWindow()
        // Held, not discarded: windows are registered weakly, so a dropped one
        // would leave `windows` with nothing to filter and the test green for
        // the wrong reason.
        let window = openPrivateWindow(store)
        #expect(store.windows.contains { $0 === window })

        let layouts = store.captureWindowLayouts()
        #expect(layouts.count == 1)
        // The ordinal is the identity a restored scene is matched by, so the
        // survivors must stay 0..n rather than keeping a hole.
        #expect(layouts.map(\.ordinal) == [0])
    }

    @Test("Restore never resurrects a private Space found on disk")
    func restoreDropsPrivateSpaces() async {
        let privateSpace = Space(name: "Private", sortIndex: 1, isPrivate: true)
        let normal = Space(name: "Personal", sortIndex: 0)
        let repo = FakeTabRepository(
            stored: [
                TabBuilder().url("https://normal.example").space(normal.id).build(),
                TabBuilder().url("https://secret.example").space(privateSpace.id).build(),
            ],
            spaces: [normal, privateSpace]
        )
        let store = TabStore(
            engine: FakeWebEngine(), repository: repo, spaceRepository: repo, clock: FixedClock()
        )

        await store.restore()

        #expect(store.spaces.contains { $0.isPrivate } == false)
        // Dropped rather than adopted into a real Space — the one place a tab is
        // deliberately not re-homed.
        #expect(store.tabs.contains { $0.focusedPane.url.host() == "secret.example" } == false)
        #expect(store.tabs.contains { $0.focusedPane.url.host() == "normal.example" })
    }

    @Test("A private page is never recorded in history")
    func historyIsNotRecorded() async {
        let history = SpyHistory()
        let (store, _, _) = await makeStore(
            stored: [TabBuilder().url("https://normal.example").build()], history: history
        )
        _ = store.claimWindow()
        let window = openPrivateWindow(store)
        let paneID = try! #require(store.selectedTab(in: window)?.focusedPaneID)

        let url = URL(string: "https://secret.example/page")!
        store.paneDidUpdate(paneID, snapshot: PaneSnapshot(url: url, isLoading: true))
        store.paneDidUpdate(
            paneID, snapshot: PaneSnapshot(url: url, title: "Secret", isLoading: false)
        )

        try? await Task.sleep(for: .milliseconds(150))
        #expect(await history.snapshot().isEmpty)
    }

    @Test("A private tab is never swept, so it is never archived either")
    func sweepSkipsPrivateTabs() async {
        let stale = Date(timeIntervalSince1970: 1_700_000_000)
        let archive = SpyArchive()
        let (store, _, _) = await makeStore(
            stored: [TabBuilder().url("https://normal.example").lastAccessed(stale).build()],
            archive: archive,
            clock: FixedClock(now: stale.addingTimeInterval(3_600))
        )
        _ = store.claimWindow()
        let window = openPrivateWindow(store)
        let privateTab = try! #require(store.selectedTab(in: window))
        // Backdate it and look away, so idleness alone would take it.
        if let index = store.tabs.firstIndex(where: { $0.id == privateTab.id }) {
            store.tabs[index].lastAccessedAt = stale
        }
        store.newTab(url: URL(string: "https://second.example")!, in: window)

        store.idleWindow = .after(60)
        await store.sweepNow()

        #expect(store.tabs.contains { $0.id == privateTab.id })
        // The decisive half: archiving writes the URL and title to disk.
        #expect(await archive.count() == 0)
    }

    @Test("Closing a private tab does not put it in the reopen list")
    func recentlyClosedSkipsPrivateTabs() async {
        let (store, _, _) = await makeStore(stored: [
            TabBuilder().url("https://normal.example").build()
        ])
        _ = store.claimWindow()
        let window = openPrivateWindow(store)
        store.newTab(url: URL(string: "https://secret.example")!, in: window)
        let tab = try! #require(store.selectedTab(in: window))

        store.closeTab(tab.id, in: window)

        // `recentlyClosed` is store-wide, so without the guard Cmd+Shift+T in a
        // *normal* window would reopen a page from a session that has ended.
        #expect(store.recentlyClosed.contains { $0.id == tab.id } == false)
    }

    // MARK: - Vault

    @Test("A private sign-in never offers to save the password")
    func vaultNeverOffersToSaveInPrivate() async {
        let (store, _, _) = await makeStore()
        _ = store.claimWindow()
        let window = openPrivateWindow(store)
        let paneID = try! #require(store.selectedTab(in: window)?.focusedPaneID)

        await store.handleSubmittedLogin(
            origin: "https://example.com", username: "me", password: "hunter2", paneID: paneID
        )

        #expect(store.pendingCredentialSave == nil)
        // The store-wide carry-over must not be primed either, or a later normal
        // window would offer to save a username typed in private.
        #expect(store.lastSubmittedUsernames.isEmpty)
    }

    // MARK: - Isolation between windows

    @Test("A normal window never adopts the private Space when its own is deleted")
    func normalWindowNeverAdoptsThePrivateSpace() async {
        let (store, _, _) = await makeStore(stored: [
            TabBuilder().url("https://normal.example").build()
        ])
        let primary = store.claimWindow()
        let second = store.claimWindow()
        let privateWindow = openPrivateWindow(store)

        // The dangerous shape: a window is left holding a Space that is gone,
        // and `reconcile`'s fallback picks the first Space it can see. Staged by
        // hand — the private Space is the *only* candidate an unscoped fallback
        // would find, which is what the scoping exists to refuse.
        let normalSpaces = store.visibleSpaces
        store.spaces.removeAll { !$0.isPrivate }
        second.activeSpaceID = UUID()
        store.reconcile(second)
        #expect(store.isPrivate(spaceID: second.activeSpaceID) == false)
        #expect(second.selectedTabID == nil, "better no tab than a private one")
        store.spaces.insert(contentsOf: normalSpaces, at: 0)
        store.reconcileWindows()

        #expect(store.isPrivate(spaceID: second.activeSpaceID) == false)
        #expect(store.isPrivate(spaceID: primary.activeSpaceID) == false)
        #expect(store.isPrivate(spaceID: privateWindow.activeSpaceID))
        // The multi-window invariant still holds across the mix.
        for window in store.windows {
            guard let selected = window.selectedTabID else { continue }
            #expect(store.windowShowing(selected, excluding: window) == nil)
        }
    }

    @Test("A private window cannot be moved off its Space, and Cmd+1…9 cannot reach it")
    func spaceSelectionIsLocked() async {
        let (store, _, _) = await makeStore()
        let primary = store.claimWindow()
        let window = openPrivateWindow(store)
        let privateSpaceID = try! #require(window.privateSpaceID)
        let normalSpaceID = try! #require(store.visibleSpaces.first?.id)

        store.selectSpace(normalSpaceID, in: window)
        #expect(window.activeSpaceID == privateSpaceID, "a private window stays where it is")

        store.selectSpace(privateSpaceID, in: primary)
        #expect(primary.activeSpaceID != privateSpaceID, "and nothing else can go there")

        // Cmd+1…9 indexes the visible Spaces, so the private one has no index.
        store.selectSpace(atIndex: store.spaces.count - 1, in: primary)
        #expect(store.isPrivate(spaceID: primary.activeSpaceID) == false)
    }

    @Test("The command bar in a normal window cannot reach a private tab, or the reverse")
    func commandBarIsScopedToTheWindowKind() async {
        let (store, _, _) = await makeStore(stored: [
            TabBuilder().url("https://normal.example").title("Normal page").build()
        ])
        let primary = store.claimWindow()
        let window = openPrivateWindow(store)
        store.newTab(url: URL(string: "https://secret.example")!, in: window)
        if let index = store.tabs.firstIndex(where: {
            $0.focusedPane.url.host() == "secret.example"
        }) {
            store.tabs[index].panes[0].title = "Secret page"
        }

        // Found live: the bar ranks open tabs from *every* Space, so without
        // this a normal window could switch straight to a private tab.
        let fromNormal = store.suggestions(for: "page", in: primary)
        #expect(fromNormal.contains { $0.title.contains("Secret") } == false)
        #expect(fromNormal.contains { $0.title.contains("Normal") })

        let fromPrivate = store.suggestions(for: "page", in: window)
        #expect(fromPrivate.contains { $0.title.contains("Normal") } == false)
        #expect(fromPrivate.contains { $0.title.contains("Secret") })
    }

    // MARK: - Link context menu

    @Test("Open Link in New Private Window opens the link, not the new-tab page")
    func privateWindowCanOpenALink() async {
        let (store, _, _) = await makeStore()
        _ = store.claimWindow()
        var opened = false
        store.privateWindowPresenter = { opened = true }

        let url = URL(string: "https://secret.example/article")!
        store.paneRequestedPrivateWindow(url: url)
        #expect(opened, "the store asks the scene layer; only it can open a window")

        let window = store.claimWindow()
        #expect(window.isPrivate)
        #expect(store.selectedTab(in: window)?.focusedPane.url == url)
    }

    @Test("Open Link in New Tab from a private page stays in that private window")
    func backgroundTabStaysInItsWindow() async {
        let (store, _, _) = await makeStore(stored: [
            TabBuilder().url("https://normal.example").build()
        ])
        let primary = store.claimWindow()
        let window = openPrivateWindow(store)
        let paneID = try! #require(store.selectedTab(in: window)?.focusedPaneID)
        let before = window.selectedTabID

        store.paneRequestedBackgroundTab(
            url: URL(string: "https://secret.example/two")!, fromPane: paneID
        )

        // Same window, same private Space — a link opened from a private page
        // must not escape into the normal session.
        let opened = try! #require(
            store.tabs.first { $0.focusedPane.url.host() == "secret.example" }
        )
        #expect(opened.spaceID == window.privateSpaceID)
        #expect(store.isPrivate(spaceID: opened.spaceID))
        // Background: you stay on the page you were reading.
        #expect(window.selectedTabID == before)
        #expect(store.selectedTab(in: primary)?.focusedPane.url.host() == "normal.example")
    }

    @Test("A popup from a private page lands in that private window and session")
    func popupStaysInItsPrivateWindow() async {
        let (store, _, engine) = await makeStore(stored: [
            TabBuilder().url("https://normal.example").build()
        ])
        _ = store.claimWindow()
        let window = openPrivateWindow(store)
        let paneID = try! #require(store.selectedTab(in: window)?.focusedPaneID)
        let popupPaneID = UUID()

        engine.emitPopupRequest(
            url: URL(string: "https://accounts.google.example")!,
            popupPaneID: popupPaneID,
            fromPane: paneID
        )

        let popup = store.tabs.first { $0.focusedPaneID == popupPaneID }
        #expect(popup != nil, "the popup becomes a tab")
        #expect(popup?.spaceID == window.privateSpaceID, "it stays in the private session")
        #expect(store.selectedTab(in: window)?.focusedPaneID == popupPaneID, "it is focused")

        // window.close() closes the popup tab, leaving the private opener intact.
        engine.emitPopupClosed(popupPaneID)
        #expect(store.tabs.allSatisfy { $0.focusedPaneID != popupPaneID })
        #expect(store.selectedTab(in: window) != nil)
    }

    // MARK: - Teardown

    @Test("Closing the window ends the session — tabs, Space, views, and data store")
    func closingTearsEverythingDown() async {
        let (store, _, engine) = await makeStore(stored: [
            TabBuilder().url("https://normal.example").build()
        ])
        let primary = store.claimWindow()
        let window = openPrivateWindow(store)
        let spaceID = try! #require(window.privateSpaceID)
        store.newTab(url: URL(string: "https://secret.example")!, in: window)
        let paneIDs = store.tabs.filter { $0.spaceID == spaceID }.map(\.focusedPaneID)
        #expect(!paneIDs.isEmpty)

        store.unregister(window)

        #expect(store.spaces.contains { $0.id == spaceID } == false)
        #expect(store.tabs.contains { $0.spaceID == spaceID } == false)
        for paneID in paneIDs {
            #expect(engine.evictedPanes.contains(paneID), "its web views are torn down")
        }
        // `removeData` is what drops the cached `.nonPersistent()` store — the
        // cookie jar would otherwise outlive the window in memory.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(engine.removedDataForSpaces.contains(spaceID))
        // And the window that remains is still showing something real.
        #expect(store.selectedTab(in: primary) != nil)
        #expect(store.isPrivate(spaceID: primary.activeSpaceID) == false)
    }

    @Test("An OS-opened URL never joins a private session")
    func osURLsAvoidPrivateWindows() async {
        let (store, _, _) = await makeStore(stored: [
            TabBuilder().url("https://normal.example").build()
        ])
        let primary = store.claimWindow()
        let window = openPrivateWindow(store)
        store.windowDidBecomeFocused(window)

        #expect(store.focusedWindow === window)
        // A link from Mail has nothing to do with the private window that
        // happens to be in front.
        #expect(store.focusedNonPrivateWindow === primary)
    }
}
