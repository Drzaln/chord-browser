import Foundation

/// Persistence seam. Declared in Core so fakes need no SQLite involvement.
///
/// M2 adds a `spaceID` parameter; M1 loads the single flat list.
public protocol TabRepository: Sendable {
    func loadAll() async throws -> [Tab]
    func save(_ tabs: [Tab]) async throws
    func loadInteractionState(paneID: UUID) async throws -> Data?
    func saveInteractionState(_ data: Data?, paneID: UUID) async throws
}
