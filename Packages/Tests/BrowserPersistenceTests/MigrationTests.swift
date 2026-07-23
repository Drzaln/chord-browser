import Foundation
import GRDB
import Testing

@testable import BrowserPersistence

/// Each migration gets a test that runs it against a fixture database from the
/// prior version (7.2). v1 has no prior version, so it is tested against an
/// empty file — the shape every future fixture will be captured from.
@Suite("Schema migrations")
struct MigrationTests {

    @Test("v1 creates the expected tables")
    func v1CreatesTables() throws {
        let queue = try DatabaseQueue()
        try Migrations.makeMigrator().migrate(queue)

        let existing = try queue.read { db in
            try ["tab", "pane", "paneInteractionState"].filter { try db.tableExists($0) }
        }
        #expect(existing == ["tab", "pane", "paneInteractionState"])
    }

    @Test("Migrating twice is a no-op")
    func idempotent() throws {
        let queue = try DatabaseQueue()
        let migrator = Migrations.makeMigrator()
        try migrator.migrate(queue)
        try migrator.migrate(queue)

        let completed = try queue.read { db in try migrator.hasCompletedMigrations(db) }
        #expect(completed)
    }

    @Test("Deleting a tab cascades to its panes")
    func cascadeDelete() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try Migrations.makeMigrator().migrate(queue)

        let tabID = UUID().uuidString
        try queue.write { db in
            try TabRow(
                id: tabID,
                placementKind: "ephemeral",
                placementOrder: 0,
                focusedPaneID: UUID().uuidString,
                lastAccessedAt: 0,
                createdAt: 0
            ).insert(db)
            try PaneRow(
                id: UUID().uuidString,
                tabId: tabID,
                position: 0,
                url: "https://example.com",
                title: "",
                faviconData: nil,
                widthFraction: 1
            ).insert(db)
        }

        try queue.write { db in
            _ = try TabRow.deleteOne(db, key: tabID)
        }
        let remaining = try queue.read { db in try PaneRow.fetchCount(db) }
        #expect(remaining == 0)
    }

    @Test("A fresh database reports the current schema version")
    func versionRecorded() throws {
        let queue = try DatabaseQueue()
        let migrator = Migrations.makeMigrator()
        try migrator.migrate(queue)

        let applied = try queue.read { db in try migrator.appliedIdentifiers(db) }
        #expect(applied.contains("v1_initial"))
        #expect(applied.count == Migrations.currentVersion)
    }
}
