import ChordCore
import ChordEngine
import Foundation
import Testing
import WebKit

@testable import ChordExtensions

/// M7 phase 7.1: the per-Space controller registry. Loading real extensions is
/// a later phase; what 7.1 owns is that each Space gets its own controller and
/// an extension-free Space gets none. See ADR 011.
///
/// The `ExtensionControllerHandle`'s controller is internal to `ChordEngine`
/// by design — no WebKit type escapes the seam — so these tests reach the
/// controllers through the host's own storage via `@testable`.
@MainActor
struct PerSpaceControllerTests {
    private func space(_ name: String) -> Space {
        Space(name: name, sortIndex: 0)
    }

    @Test func freshHostHasNoControllersUntilAViewAsksForOne() {
        // Nothing is prepared until a web view is created for a Space (or an
        // extension loads). A brand-new host holds none.
        let host = WebKitExtensionHost()
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

    @Test func handleAlwaysAttachesAControllerEvenWithoutExtensions() {
        // Every web view must get a controller at creation, because
        // `WKWebViewConfiguration.webExtensionController` cannot be added later
        // — otherwise an extension enabled after a tab is open could never run
        // in it. So requesting a handle prepares (attaches) one on demand.
        let host = WebKitExtensionHost()
        let s = space("A")
        #expect(host.extensionControllerHandle(for: s) != nil)
        #expect(host.preparedSpaceIDs == [s.id])
        // Idempotent: a second request does not create a second controller.
        let controller = host.controllers[s.id]
        _ = host.extensionControllerHandle(for: s)
        #expect(host.controllers.count == 1)
        #expect(host.controllers[s.id] === controller)
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
