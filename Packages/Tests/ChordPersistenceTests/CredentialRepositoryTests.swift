import ChordCore
import Foundation
import GRDB
import Testing

@testable import ChordPersistence

/// The vault's metadata store (V2). Nothing here handles a password — that is
/// `ChordSecrets`, and the fact that these tests never mention one is the point.
@Suite("Credential repository")
struct CredentialRepositoryTests {

    private func makeRepository() throws -> SQLiteCredentialRepository {
        SQLiteCredentialRepository(database: try ChordDatabase.inMemory())
    }

    /// `lastUsedSpaceId` carries a foreign key to `space` — deliberately, so that
    /// deleting a Space nulls the hint instead of orphaning it — which means a
    /// test recording a use has to reference a Space that actually exists.
    private func makeRepositoryWithSpace() async throws
        -> (SQLiteCredentialRepository, ChordCore.Space)
    {
        let database = try ChordDatabase.inMemory()
        let space = ChordCore.Space(name: "Work", sortIndex: 0)
        try await SQLiteTabRepository(database: database).saveSpaces([space])
        return (SQLiteCredentialRepository(database: database), space)
    }

    @Test("A saved credential comes back for its origin")
    func roundTrip() async throws {
        let repository = try makeRepository()
        try await repository.upsert(
            Credential(origin: "https://example.com", username: "me@example.com")
        )

        let found = try await repository.credentials(
            forOrigin: "https://example.com", spaceID: nil
        )
        #expect(found.count == 1)
        #expect(found.first?.username == "me@example.com")
    }

    @Test("A different origin sees nothing")
    func originScoped() async throws {
        let repository = try makeRepository()
        try await repository.upsert(
            Credential(origin: "https://example.com", username: "me@example.com")
        )
        #expect(
            try await repository.credentials(forOrigin: "https://other.com", spaceID: nil).isEmpty
        )
    }

    @Test("Two accounts on one site both persist — the case Spaces exist for")
    func multipleAccountsPerOrigin() async throws {
        let repository = try makeRepository()
        try await repository.upsert(Credential(origin: "https://mail.com", username: "work"))
        try await repository.upsert(Credential(origin: "https://mail.com", username: "personal"))

        let found = try await repository.credentials(forOrigin: "https://mail.com", spaceID: nil)
        #expect(found.count == 2)
    }

    @Test("Re-saving the same login keeps the id, so its secret is not orphaned")
    func upsertKeepsIdentity() async throws {
        let repository = try makeRepository()
        let first = try await repository.upsert(
            Credential(origin: "https://example.com", username: "me@example.com")
        )
        let second = try await repository.upsert(
            Credential(origin: "https://example.com", username: "me@example.com")
        )

        #expect(second.id == first.id, "a re-save must not mint a new id")
        #expect(try await repository.all().count == 1, "and must not duplicate the row")
    }

    @Test("Marking a credential used records when and where")
    func markUsed() async throws {
        let (repository, space) = try await makeRepositoryWithSpace()
        let stored = try await repository.upsert(
            Credential(origin: "https://example.com", username: "me@example.com")
        )
        let when = Date(timeIntervalSince1970: 1_700_000_000)

        try await repository.markUsed(id: stored.id, at: when, inSpace: space.id)

        let reloaded = try await repository.all().first
        #expect(reloaded?.lastUsedAt == when)
        #expect(reloaded?.lastUsedSpaceID == space.id)
    }

    @Test("Deleting removes it from every view")
    func delete() async throws {
        let repository = try makeRepository()
        let stored = try await repository.upsert(
            Credential(origin: "https://example.com", username: "me@example.com")
        )
        try await repository.delete(id: stored.id)

        #expect(try await repository.all().isEmpty)
        #expect(try await repository.storedIDs().isEmpty)
    }

    // MARK: - Picker ordering

    private func credential(
        _ username: String, lastUsed: TimeInterval?, space: UUID? = nil
    ) -> Credential {
        Credential(
            origin: "https://example.com",
            username: username,
            lastUsedAt: lastUsed.map { Date(timeIntervalSince1970: $0) },
            lastUsedSpaceID: space
        )
    }

    @Test("The account last used in this Space is offered first")
    func spaceHintWins() {
        let work = UUID()
        let ordered = SQLiteCredentialRepository.ordered(
            [
                credential("personal", lastUsed: 2_000, space: UUID()),
                credential("work", lastUsed: 1_000, space: work),
            ],
            forSpace: work
        )
        // Even though "personal" was used more recently overall.
        #expect(ordered.map(\.username) == ["work", "personal"])
    }

    @Test("With no Space hint, most recently used comes first")
    func recencyOrders() {
        let ordered = SQLiteCredentialRepository.ordered(
            [credential("older", lastUsed: 1_000), credential("newer", lastUsed: 2_000)],
            forSpace: nil
        )
        #expect(ordered.map(\.username) == ["newer", "older"])
    }

    @Test("Never-used credentials sort last, alphabetically, so the list is stable")
    func unusedSortLastAndStably() {
        let ordered = SQLiteCredentialRepository.ordered(
            [
                credential("zoe", lastUsed: nil),
                credential("adam", lastUsed: nil),
                credential("used", lastUsed: 1_000),
            ],
            forSpace: nil
        )
        #expect(ordered.map(\.username) == ["used", "adam", "zoe"])
    }

    // MARK: - Defensive decoding

    @Test("A corrupt row costs one credential, not the whole vault")
    func corruptRowIsSkipped() async throws {
        let database = try ChordDatabase.inMemory()
        let repository = SQLiteCredentialRepository(database: database)
        try await repository.upsert(
            Credential(origin: "https://good.com", username: "fine")
        )
        // An id that is not a UUID — the shape a hand-edited or half-written row
        // takes. It must not take the good row down with it (§3.7).
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO credential (id, origin, username, createdAt)
                    VALUES ('not-a-uuid', 'https://bad.com', 'broken', ?)
                    """,
                arguments: [Date()]
            )
        }

        let all = try await repository.all()
        #expect(all.count == 1)
        #expect(all.first?.origin == "https://good.com")
    }
}
