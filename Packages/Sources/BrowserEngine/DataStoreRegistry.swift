import BrowserCore
import Foundation
import WebKit

/// Maps Spaces to `WKWebsiteDataStore`s.
///
/// This is where Space isolation actually happens. Each Space gets its own
/// store via `WKWebsiteDataStore(forIdentifier:)`, which gives fully separate
/// cookies, localStorage, and cache as first-class WebKit API — two accounts on
/// the same site, logged in at once, with no profile switching (3.3).
@MainActor
final class DataStoreRegistry {
    /// Created lazily on first use and cached by Space id (3.3).
    private var stores: [UUID: WKWebsiteDataStore] = [:]

    func store(for space: Space) -> WKWebsiteDataStore {
        if let existing = stores[space.id] { return existing }

        let store: WKWebsiteDataStore
        if space.isPrivate {
            // Nothing survives a quit, by design.
            store = .nonPersistent()
        } else {
            store = WKWebsiteDataStore(forIdentifier: space.dataStoreID)
        }

        stores[space.id] = store
        Log.engine.debug("opened data store for space \(space.id)")
        return store
    }

    func forget(spaceID: UUID) {
        stores[spaceID] = nil
    }

    /// Reclaims the Space's disk. Irreversible — the caller must have prompted
    /// before getting here (3.3).
    func removePersistentStore(dataStoreID: UUID) async throws {
        try await WKWebsiteDataStore.remove(forIdentifier: dataStoreID)
        Log.engine.notice("removed data store \(dataStoreID)")
    }
}
