import Foundation

/// Persistence seam. Declared in Core so fakes need no SQLite involvement.
public protocol TabRepository: Sendable {
    /// Every tab across every Space. The store partitions in memory — the tab
    /// set is small, and a single load keeps Space switching off the disk.
    func loadAll() async throws -> [Tab]
    func save(_ tabs: [Tab]) async throws
    func loadInteractionState(paneID: UUID) async throws -> Data?
    func saveInteractionState(_ data: Data?, paneID: UUID) async throws

    /// Drops state for panes that no longer exist.
    ///
    /// The blob table is deliberately not foreign-keyed to `pane` — the blobs
    /// are written and read on a different schedule than the tab rows, and a
    /// cascade would delete state during the delete-and-reinsert that `save`
    /// does. So nothing reclaims them automatically, and closed tabs would leak
    /// their state forever. These blobs are the largest thing we store (6.5).
    func pruneInteractionStates(keeping paneIDs: Set<UUID>) async throws
}

public protocol SpaceRepository: Sendable {
    func loadSpaces() async throws -> [Space]
    func saveSpaces(_ spaces: [Space]) async throws
}
