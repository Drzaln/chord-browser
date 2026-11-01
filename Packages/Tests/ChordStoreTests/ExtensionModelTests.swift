import AppKit
import ChordCore
import ChordEngine
import ChordExtensions
import ChordTestSupport
import Foundation
import Testing
import WebKit

@testable import ChordStore

/// Records the tab-lifecycle hooks the Store fires (7.3b). The non-lifecycle
/// members are inert — these tests only exercise open/activate/close.
@MainActor
private final class RecordingExtensionHost: ExtensionHost {
    var opened: [(UUID, UUID)] = []
    var activated: [(UUID, UUID?, UUID)] = []
    var closed: [(UUID, UUID)] = []
    var resolved: [(UUID, Bool)] = []

    func extensionTabDidOpen(_ tabID: UUID, inSpace spaceID: UUID) {
        opened.append((tabID, spaceID))
    }
    func extensionTabDidActivate(_ tabID: UUID, previous: UUID?, inSpace spaceID: UUID) {
        activated.append((tabID, previous, spaceID))
    }
    func extensionTabDidClose(_ tabID: UUID, inSpace spaceID: UUID) {
        closed.append((tabID, spaceID))
    }
    func extensionTabDidMove(_ tabID: UUID, from oldIndex: Int, inSpace spaceID: UUID) {}
    var groupChanges = 0
    func extensionGroupsDidChange() { groupChanges += 1 }
    var stoppedRecordings: [String] = []
    func stopRecording(id: String) { stoppedRecordings.append(id) }

    var closedSpaces: [UUID] = []
    var onSpaceDidClose: ((Space) -> Void)?
    func spaceDidClose(_ space: Space) async {
        closedSpaces.append(space.id)
        onSpaceDidClose?(space)
    }

    // Unused by these tests.
    var preparedSpaceIDs: Set<UUID> { [] }
    func prepare(_ space: Space) -> ExtensionControllerHandle {
        ExtensionControllerHandle(WKWebExtensionController())
    }
    func extensionControllerHandle(for space: Space) -> ExtensionControllerHandle? { nil }
    func load(_ installed: InstalledExtension, in space: Space) async throws -> LoadedExtension {
        fatalError("unused")
    }
    func unload(slug: String, in space: Space) throws {}
    func loadedExtensions(in space: Space) -> [LoadedExtension] { [] }
    func actions(in space: Space) -> [ExtensionActionSnapshot] { [] }
    var onActionsChanged: (@MainActor () -> Void)?
    var onPopupVisibilityChanged: (@MainActor (AnyObject?, Bool) -> Void)?
    func registerActionAnchor(_ view: NSView?, forSlug slug: String, in space: Space) {}
    func presentAction(slug: String, in space: Space) {}
    var onPermissionRequest: (@MainActor (PermissionRequest) -> Void)?
    func resolvePermission(id: UUID, allow: Bool) { resolved.append((id, allow)) }
    func hasAllHostsAccess(slug: String, in space: Space) -> Bool { false }
    func setAllHostsAccess(_ granted: Bool, slug: String, in space: Space) {}
    var onHostAccessChanged: (@MainActor (UUID) -> Void)?
    func promptForHostAccess(slug: String, in space: Space) {}
}

@MainActor
struct ExtensionModelTests {
    private func makeStore() async -> (TabStore, RecordingExtensionHost) {
        let store = TabStore(
            engine: FakeWebEngine(), repository: FakeTabRepository(), clock: FixedClock()
        )
        await store.restore()
        let host = RecordingExtensionHost()
        store.extensionHost = host
        return (store, host)
    }

    /// 1mm.15: the recording pill's Stop reaches the extension's recording.
    @Test("The recording pill's Stop ends that extension's recording")
    func recordingPillStop() async {
        let (store, host) = await makeStore()
        store.extensionRecordings = [
            ExtensionRecording(id: "loom", name: "Loom", screen: true, camera: false, microphone: false)
        ]
        store.stopExtensionRecording(id: "loom")
        #expect(host.stoppedRecordings == ["loom"])
    }

    /// c1k.5: workers hear about tab groups instead of asking every 3 s.
    @Test("Adding, renaming, collapsing or deleting a folder tells the extensions")
    func folderChangesReachExtensions() async throws {
        let (store, host) = await makeStore()
        let id = try #require(store.addFolder(name: "Work"))
        store.renameFolder(id, to: "Play")
        store.toggleFolderCollapsed(id)
        store.deleteFolder(id)
        #expect(host.groupChanges == 4)
    }

    @Test("Deleting a Space closes its extensions before its data goes")
    func deleteSpaceClosesItsExtensions() async {
        let engine = FakeWebEngine()
        let store = TabStore(engine: engine, repository: FakeTabRepository(), clock: FixedClock())
        await store.restore()
        let host = RecordingExtensionHost()
        store.extensionHost = host
        let doomed = store.addSpace(in: store.primaryWindow)
        var dataGoneFirst: Bool?
        host.onSpaceDidClose = { dataGoneFirst = engine.removedDataForSpaces.contains($0.id) }

        await store.deleteSpace(doomed.id, in: store.primaryWindow)

        #expect(host.closedSpaces == [doomed.id])
        #expect(dataGoneFirst == false, "the controller lets go of the store first")
        #expect(engine.removedDataForSpaces.contains(doomed.id))
    }

    @Test("Closing a private window closes its Space's extensions")
    func privateWindowClosesItsExtensions() async {
        let engine = FakeWebEngine()
        let store = TabStore(engine: engine, repository: FakeTabRepository(), clock: FixedClock())
        await store.restore()
        let host = RecordingExtensionHost()
        store.extensionHost = host
        _ = store.claimWindow()
        store.markNextWindowPrivate()
        let window = store.claimWindow()
        let spaceID = try! #require(window.privateSpaceID)
        var dataGoneFirst: Bool?
        host.onSpaceDidClose = { dataGoneFirst = engine.removedDataForSpaces.contains($0.id) }

        store.unregister(window)
        for _ in 0..<50 where !engine.removedDataForSpaces.contains(spaceID) {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(host.closedSpaces == [spaceID])
        #expect(dataGoneFirst == false)
        #expect(engine.removedDataForSpaces.contains(spaceID))
    }

    /// Two idle loose tabs in a fresh store, then a new selected one, so a
    /// sweep takes exactly the first two. Each idle pane has a load in flight.
    private func storeWithIdleTabs() async -> (TabStore, RecordingExtensionHost, [Tab]) {
        let stale = Date(timeIntervalSince1970: 1_700_000_000)
        let store = TabStore(
            engine: FakeWebEngine(),
            repository: FakeTabRepository(stored: [
                TabBuilder().url("https://a.example").lastAccessed(stale).build(),
                TabBuilder().url("https://b.example").lastAccessed(stale).build(),
            ]),
            clock: FixedClock(now: stale.addingTimeInterval(3_600))
        )
        await store.restore()
        let host = RecordingExtensionHost()
        store.extensionHost = host
        let idle = store.tabs
        store.newTab(url: URL(string: "https://fresh.example")!)
        for tab in idle {
            store.paneDidUpdate(
                tab.focusedPaneID,
                snapshot: PaneSnapshot(url: tab.focusedPane.url, isLoading: true)
            )
            store.stateResolution[tab.focusedPaneID] = .resolved
            store.openedPaneIDs.insert(tab.focusedPaneID)
        }
        return (store, host, idle)
    }

    /// Nothing a removed pane had is left behind in the store.
    private func expectForgotten(_ tabs: [Tab], in store: TabStore) {
        for paneID in tabs.flatMap({ $0.panes.map(\.id) }) {
            #expect(store.runtimes[paneID] == nil)
            #expect(store.pendingHistoryURL[paneID] == nil)
            #expect(store.stateResolution[paneID] == nil)
            #expect(!store.openedPaneIDs.contains(paneID))
        }
    }

    @Test("Swept tabs reach extensions as closed, and leave nothing behind")
    func sweepTellsExtensions() async {
        let (store, host, idle) = await storeWithIdleTabs()
        store.idleWindow = .after(60)

        await store.sweepNow()

        #expect(!store.tabs.contains { tab in idle.contains { $0.id == tab.id } })
        for tab in idle {
            #expect(host.closed.contains { $0.0 == tab.id && $0.1 == tab.spaceID })
        }
        expectForgotten(idle, in: store)
    }

    @Test("A deleted Space's tabs reach extensions as closed, and leave nothing behind")
    func deleteSpaceTellsExtensions() async {
        let (store, host, idle) = await storeWithIdleTabs()
        let doomed = store.addSpace(in: store.primaryWindow)
        // Rehomed in place: what's under test is the delete, not the move.
        for tab in idle {
            if let index = store.tabs.firstIndex(where: { $0.id == tab.id }) {
                store.tabs[index].spaceID = doomed.id
            }
        }
        // The new Space opened with a blank tab of its own; it goes too.
        let moved = store.tabs.filter { $0.spaceID == doomed.id }
        #expect(moved.count == idle.count + 1)

        await store.deleteSpace(doomed.id, in: store.primaryWindow)

        for tab in moved {
            #expect(host.closed.contains { $0.0 == tab.id && $0.1 == doomed.id })
        }
        expectForgotten(moved, in: store)
    }

    @Test("Closing a tab leaves no runtime behind")
    func closeTabForgetsItsRuntime() async {
        let (store, _, idle) = await storeWithIdleTabs()
        let tab = idle[0]

        store.closeTab(tab.id)

        expectForgotten([tab], in: store)
    }

    @Test func newTabFiresOpenThenActivate() async {
        let (store, host) = await makeStore()
        let spaceID = store.activeSpaceID!

        store.newTab(url: URL(string: "https://example.com")!)
        let newID = store.selectedTabID!

        #expect(host.opened.contains { $0.0 == newID && $0.1 == spaceID })
        #expect(host.activated.contains { $0.0 == newID && $0.2 == spaceID })
    }

    @Test func closeTabFiresClose() async {
        let (store, host) = await makeStore()
        store.newTab(url: URL(string: "https://example.com")!)
        let id = store.selectedTabID!
        let spaceID = store.activeSpaceID!

        store.closeTab(id)
        #expect(host.closed.contains { $0.0 == id && $0.1 == spaceID })
    }

    @Test func modelReportsTheActiveTabSnapshot() async {
        let (store, _) = await makeStore()
        let spaceID = store.activeSpaceID!
        store.newTab(url: URL(string: "https://example.com/page")!)
        let id = store.selectedTabID!

        let active = store.extensionActiveTab(inSpace: spaceID)
        #expect(active?.id == id)
        #expect(active?.url == URL(string: "https://example.com/page"))
        #expect(active?.isSelected == true)
        // A tab from another (nonexistent) Space is not reported here.
        #expect(store.extensionActiveTab(inSpace: UUID()) == nil)
    }

    @Test func moveTabAcrossSpacesFiresCloseThenOpen() async {
        let (store, host) = await makeStore()
        let fromSpace = store.activeSpaceID!
        let toSpace = Space(name: "Other", sortIndex: 1)
        store.spaces.append(toSpace)
        store.newTab(url: URL(string: "https://example.com")!)
        let id = store.selectedTabID!

        store.moveTab(id, toSpace: toSpace.id)

        // The extension in the source Space sees it leave; the destination sees
        // it arrive.
        #expect(host.closed.contains { $0.0 == id && $0.1 == fromSpace })
        #expect(host.opened.contains { $0.0 == id && $0.1 == toSpace.id })
    }

    @Test func resolvingAPermissionForwardsToHostAndClearsTheQueue() async {
        let (store, host) = await makeStore()
        let req = PermissionRequest(
            id: UUID(), slug: "ext", spaceID: store.activeSpaceID!,
            kind: .matchPattern, items: ["*://*/*"], displayName: "Ext"
        )
        store.pendingPermissionRequests.append(req)

        store.resolvePermissionRequest(req.id, allow: true)

        #expect(host.resolved.contains { $0.0 == req.id && $0.1 == true })
        #expect(store.pendingPermissionRequests.isEmpty)
    }

    @Test func modelListsTabsInTheSpaceInOrder() async {
        let (store, _) = await makeStore()
        let spaceID = store.activeSpaceID!
        let before = store.extensionTabs(inSpace: spaceID).count

        store.newTab(url: URL(string: "https://a.test")!)
        store.newTab(url: URL(string: "https://b.test")!)

        let tabs = store.extensionTabs(inSpace: spaceID)
        #expect(tabs.count == before + 2)
        // Indices are dense and ordered.
        #expect(tabs.map(\.index) == Array(0..<tabs.count))
    }
}
