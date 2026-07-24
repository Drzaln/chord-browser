import AppKit
import BrowserCore
import BrowserEngine
import BrowserExtensions
import BrowserTestSupport
import Foundation
import Testing
import WebKit

@testable import BrowserStore

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
    func registerActionAnchor(_ view: NSView?, forSlug slug: String, in space: Space) {}
    func presentAction(slug: String, in space: Space) {}
    var onPermissionRequest: (@MainActor (PermissionRequest) -> Void)?
    func resolvePermission(id: UUID, allow: Bool) { resolved.append((id, allow)) }
    func hasAllHostsAccess(slug: String, in space: Space) -> Bool { false }
    func setAllHostsAccess(_ granted: Bool, slug: String, in space: Space) {}
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
