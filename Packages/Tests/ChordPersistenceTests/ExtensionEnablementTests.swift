import ChordCore
import Foundation
import GRDB
import Testing

@testable import ChordPersistence

@Suite("Extension enablement (7.4)")
struct ExtensionEnablementTests {
    /// A database with one Space seeded, so enablement rows satisfy the Space
    /// foreign key.
    private func makeDBWithSpace() async throws -> (ChordDatabase, Space) {
        let db = try ChordDatabase.inMemory()
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
        #expect(Migrations.currentVersion == 15)
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
        let db = try ChordDatabase.inMemory()
        let a = Space(name: "A", sortIndex: 0)
        let b = Space(name: "B", sortIndex: 1)
        try await SQLiteTabRepository(database: db).saveSpaces([a, b])
        let repo = SQLiteExtensionEnablementRepository(database: db)

        try await repo.setEnabled(true, slug: "ublock", spaceID: a.id)

        #expect(try await repo.enabledSlugs(spaceID: a.id) == ["ublock"])
        #expect(try await repo.enabledSlugs(spaceID: b.id).isEmpty)
    }
}

/// Saving Spaces once deleted every Space row and re-inserted it, and the
/// rows that cascade from a Space went with it: any rename, reorder or new
/// Space emptied every Space's extensions, site permissions and folders.
@Suite("Saving Spaces keeps what hangs off them")
struct SpaceSaveKeepsChildrenTests {
    @Test("A save keeps a surviving Space's rows; a removed Space's go")
    func saveKeepsChildren() async throws {
        let db = try ChordDatabase.inMemory()
        let spaces = SQLiteTabRepository(database: db)
        let work = Space(name: "Work", sortIndex: 0)
        let home = Space(name: "Home", sortIndex: 1)
        try await spaces.saveSpaces([work, home])

        let enablement = SQLiteExtensionEnablementRepository(database: db)
        let sites = SQLiteSitePermissionsRepository(database: db)
        try await enablement.setEnabled(true, slug: "ublock", spaceID: work.id)
        try await enablement.setEnabled(true, slug: "ublock", spaceID: home.id)
        try await sites.setDecision(
            .granted, forOrigin: "https://meet.example", spaceID: work.id, kind: .camera
        )
        try await spaces.saveFolders([Folder(spaceID: work.id, name: "Docs", sortIndex: 0)])

        // A rename and a new Space: the everyday saves.
        var renamed = work
        renamed.name = "Office"
        try await spaces.saveSpaces([renamed, home, Space(name: "New", sortIndex: 2)])

        #expect(try await enablement.enabledSlugs(spaceID: work.id) == ["ublock"])
        #expect(try await sites.decisions(forOrigin: "https://meet.example", spaceID: work.id)
            == [.camera: .granted])
        #expect(try await spaces.loadFolders().map(\.name) == ["Docs"])
        #expect(try await spaces.loadSpaces().map(\.name) == ["Office", "Home", "New"])

        // Deleting a Space still takes its own rows.
        try await spaces.saveSpaces([renamed])
        #expect(try await enablement.enabledSlugs(spaceID: home.id).isEmpty)
        #expect(try await enablement.enabledSlugs(spaceID: work.id) == ["ublock"])
    }
}
