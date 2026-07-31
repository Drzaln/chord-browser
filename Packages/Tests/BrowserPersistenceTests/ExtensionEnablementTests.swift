import BrowserCore
import Foundation
import GRDB
import Testing

@testable import BrowserPersistence

@Suite("Extension enablement (7.4)")
struct ExtensionEnablementTests {
    /// A database with one Space seeded, so enablement rows satisfy the Space
    /// foreign key.
    private func makeDBWithSpace() async throws -> (BrowserDatabase, Space) {
        let db = try BrowserDatabase.inMemory()
        let space = Space(name: "Work", sortIndex: 0)
        try await SQLiteTabRepository(database: db).saveSpaces([space])
        return (db, space)
    }

    @Test("The v4 migration creates the enablement table")
    func migrationCreatesTable() throws {
        let queue = try DatabaseQueue()
        try Migrations.makeMigrator().migrate(queue)
        let exists = try queue.read { try $0.tableExists("extensionEnablement") }
        #expect(exists)
        #expect(Migrations.currentVersion == 13)
    }

    @Test("Enabling then reading round-trips per Space")
    func roundTrip() async throws {
        let (db, space) = try await makeDBWithSpace()
        let repo = SQLiteExtensionEnablementRepository(database: db)

        try await repo.setEnabled(true, slug: "ublock", spaceID: space.id)
        try await repo.setEnabled(true, slug: "darkreader", spaceID: space.id)

        #expect(try await repo.enabledSlugs(spaceID: space.id).sorted() == ["darkreader", "ublock"])
        #expect(
            try await repo.allEnabled().sorted { $0.slug < $1.slug }
                == [
                    ExtensionEnablementRecord(spaceID: space.id, slug: "darkreader"),
                    ExtensionEnablementRecord(spaceID: space.id, slug: "ublock"),
                ]
        )
    }

    @Test("Disabling removes the row; enabling twice is idempotent")
    func disableAndIdempotent() async throws {
        let (db, space) = try await makeDBWithSpace()
        let repo = SQLiteExtensionEnablementRepository(database: db)

        try await repo.setEnabled(true, slug: "ublock", spaceID: space.id)
        try await repo.setEnabled(true, slug: "ublock", spaceID: space.id)  // no duplicate
        #expect(try await repo.enabledSlugs(spaceID: space.id) == ["ublock"])

        try await repo.setEnabled(false, slug: "ublock", spaceID: space.id)
        #expect(try await repo.enabledSlugs(spaceID: space.id).isEmpty)
    }

    @Test("Enablement is per Space")
    func perSpace() async throws {
        let db = try BrowserDatabase.inMemory()
        let a = Space(name: "A", sortIndex: 0)
        let b = Space(name: "B", sortIndex: 1)
        try await SQLiteTabRepository(database: db).saveSpaces([a, b])
        let repo = SQLiteExtensionEnablementRepository(database: db)

        try await repo.setEnabled(true, slug: "ublock", spaceID: a.id)

        #expect(try await repo.enabledSlugs(spaceID: a.id) == ["ublock"])
        #expect(try await repo.enabledSlugs(spaceID: b.id).isEmpty)
    }
}
