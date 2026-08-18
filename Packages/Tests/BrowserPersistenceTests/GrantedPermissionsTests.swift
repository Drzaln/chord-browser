import BrowserCore
import Foundation
import GRDB
import Testing

@testable import BrowserPersistence

@Suite("Granted permissions (7.5c)")
struct GrantedPermissionsTests {
    private func makeDBWithSpace() async throws -> (BrowserDatabase, Space) {
        let db = try BrowserDatabase.inMemory()
        let space = Space(name: "Work", sortIndex: 0)
        try await SQLiteTabRepository(database: db).saveSpaces([space])
        return (db, space)
    }

    @Test("The v5 migration creates the grantedPermission table")
    func migrationCreatesTable() throws {
        let queue = try DatabaseQueue()
        try Migrations.makeMigrator().migrate(queue)
        let exists = try queue.read { try $0.tableExists("grantedPermission") }
        #expect(exists)
        #expect(Migrations.currentVersion == 14)
    }

    @Test("Granting then reading round-trips, across all three kinds")
    func roundTrip() async throws {
        let (db, space) = try await makeDBWithSpace()
        let repo = SQLiteGrantedPermissionsRepository(database: db)

        let records = [
            GrantedPermissionRecord(spaceID: space.id, slug: "ext", kind: .matchPattern, value: "*://*/*"),
            GrantedPermissionRecord(spaceID: space.id, slug: "ext", kind: .permission, value: "tabs"),
            GrantedPermissionRecord(
                spaceID: space.id, slug: "ext", kind: .url, value: "https://example.com/"),
        ]
        try await repo.grant(records)

        let read = try await repo.granted(slug: "ext", spaceID: space.id)
        #expect(Set(read) == Set(records))
    }

    @Test("Granting the same tuple twice is idempotent")
    func idempotent() async throws {
        let (db, space) = try await makeDBWithSpace()
        let repo = SQLiteGrantedPermissionsRepository(database: db)
        let record = GrantedPermissionRecord(
            spaceID: space.id, slug: "ext", kind: .matchPattern, value: "*://*/*")

        try await repo.grant([record])
        try await repo.grant([record])  // no duplicate

        #expect(try await repo.granted(slug: "ext", spaceID: space.id) == [record])
    }

    @Test("revokeAll drops only that extension's grants in that Space")
    func revokeAll() async throws {
        let (db, space) = try await makeDBWithSpace()
        let repo = SQLiteGrantedPermissionsRepository(database: db)
        try await repo.grant([
            GrantedPermissionRecord(spaceID: space.id, slug: "a", kind: .permission, value: "tabs"),
            GrantedPermissionRecord(spaceID: space.id, slug: "b", kind: .permission, value: "tabs"),
        ])

        try await repo.revokeAll(slug: "a", spaceID: space.id)

        #expect(try await repo.granted(slug: "a", spaceID: space.id).isEmpty)
        #expect(try await repo.granted(slug: "b", spaceID: space.id).count == 1)
    }

    @Test("Grants are per Space")
    func perSpace() async throws {
        let db = try BrowserDatabase.inMemory()
        let a = Space(name: "A", sortIndex: 0)
        let b = Space(name: "B", sortIndex: 1)
        try await SQLiteTabRepository(database: db).saveSpaces([a, b])
        let repo = SQLiteGrantedPermissionsRepository(database: db)

        try await repo.grant([
            GrantedPermissionRecord(spaceID: a.id, slug: "ext", kind: .matchPattern, value: "*://*/*")
        ])

        #expect(try await repo.granted(slug: "ext", spaceID: a.id).count == 1)
        #expect(try await repo.granted(slug: "ext", spaceID: b.id).isEmpty)
    }
}
