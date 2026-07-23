import Foundation

/// Persistence seam. Declared in Core so fakes need no SQLite involvement.
public protocol TabRepository: Sendable {
    /// Every tab across every Space. The store partitions in memory — the tab
    /// set is small, and a single load keeps Space switching off the disk.
    func loadAll() async throws -> [Tab]
    func save(_ tabs: [Tab]) async throws
    func loadInteractionState(paneID: UUID) async throws -> Data?
    func saveInteractionState(_ data: Data?, paneID: UUID) async throws
}

public protocol SpaceRepository: Sendable {
    func loadSpaces() async throws -> [Space]
    func saveSpaces(_ spaces: [Space]) async throws
}
