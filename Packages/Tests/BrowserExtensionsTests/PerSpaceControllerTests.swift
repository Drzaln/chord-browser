import BrowserCore
import BrowserEngine
import Foundation
import Testing
import WebKit

@testable import BrowserExtensions

/// M7 phase 7.1: the per-Space controller registry. Loading real extensions is
/// a later phase; what 7.1 owns is that each Space gets its own controller and
/// an extension-free Space gets none. See ADR 011.
///
/// The `ExtensionControllerHandle`'s controller is internal to `BrowserEngine`
/// by design — no WebKit type escapes the seam — so these tests reach the
/// controllers through the host's own storage via `@testable`.
@MainActor
struct PerSpaceControllerTests {
    private func space(_ name: String) -> Space {
        Space(name: name, sortIndex: 0)
    }

    @Test func unpreparedSpaceHasNoController() {
        let host = WebKitExtensionHost()
        #expect(host.extensionControllerHandle(for: space("A")) == nil)
        #expect(host.preparedSpaceIDs.isEmpty)
    }

    @Test func prepareIsIdempotentPerSpace() {
        let host = WebKitExtensionHost()
        let s = space("A")
        host.prepare(s)
        let firstController = host.controllers[s.id]
        host.prepare(s)
        // Same Space must yield the same controller, or its on-disk extension
        // storage would not be stable across the app's lifetime.
        #expect(host.controllers.count == 1)
        #expect(host.controllers[s.id] === firstController)
    }

    @Test func distinctSpacesGetDistinctControllers() {
        let host = WebKitExtensionHost()
        let a = space("A")
        let b = space("B")
        host.prepare(a)
        host.prepare(b)
        // The whole point of per-Space contexts (ADR 011): no sharing.
        #expect(host.controllers[a.id] !== host.controllers[b.id])
        #expect(host.preparedSpaceIDs == [a.id, b.id])
    }

    @Test func handleReturnsControllerOnlyAfterPrepare() {
        let host = WebKitExtensionHost()
        let s = space("A")
        #expect(host.extensionControllerHandle(for: s) == nil)
        host.prepare(s)
        #expect(host.extensionControllerHandle(for: s) != nil)
        #expect(host.preparedSpaceIDs == [s.id])
    }

    @Test func persistentSpaceControllerIsKeyedByDataStoreID() {
        let host = WebKitExtensionHost()
        let s = Space(name: "A", dataStoreID: UUID(), sortIndex: 0)
        host.prepare(s)
        // A persistent Space's extension storage is keyed to the same id as its
        // website data store, so extension data lands beside its cookies.
        #expect(host.controllers[s.id]?.configuration.identifier == s.dataStoreID)
    }

    @Test func privateSpaceControllerIsNonPersistent() {
        let host = WebKitExtensionHost()
        let s = Space(name: "Private", sortIndex: 0, isPrivate: true)
        host.prepare(s)
        // A private Space keeps nothing on disk, extensions included: the
        // configuration carries no persistent identifier.
        #expect(host.controllers[s.id]?.configuration.identifier == nil)
    }
}
