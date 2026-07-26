import Foundation
import GRDB
import Testing

@testable import BrowserPersistence

/// Each migration gets a test that runs it against a fixture database from the
/// prior version (7.2). v1 has no prior version, so it is tested against an
/// empty file — the shape every future fixture will be captured from.
@Suite("Schema migrations")
struct MigrationTests {

    @Test("The full migrator creates the expected tables")
    func createsTables() throws {
        let queue = try DatabaseQueue()
        try Migrations.makeMigrator().migrate(queue)

        let expected = ["tab", "pane", "paneInteractionState", "space"]
        let existing = try queue.read { db in
            try expected.filter { try db.tableExists($0) }
        }
        #expect(existing == expected)
    }

    /// The v1 fixture: a database migrated only as far as v1, with a tab in it.
    /// This is the shape 7.2 requires every future migration to be tested
    /// against — captured from the prior version, not hand-written at v2.
    private func v1Fixture(tabCount: Int) throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)

        var v1Only = DatabaseMigrator()
        v1Only.registerMigration("v1_initial") { db in
            try Migrations.v1ForTesting(db)
        }
        try v1Only.migrate(queue)

        try queue.write { db in
            for index in 0..<tabCount {
                let tabID = UUID().uuidString
                try db.execute(
                    sql: """
                        INSERT INTO tab
                            (id, placementKind, placementOrder, focusedPaneID,
                             lastAccessedAt, createdAt)
                        VALUES (?, 'ephemeral', ?, ?, 0, 0)
                        """,
                    arguments: [tabID, index, UUID().uuidString]
                )
            }
        }
        return queue
    }

    @Test("v2 adopts existing v1 tabs into a generated default Space")
    func v2AdoptsExistingTabs() throws {
        let queue = try v1Fixture(tabCount: 3)

        try Migrations.makeMigrator().migrate(queue)

        let (spaceCount, tabCount, orphanCount) = try queue.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM space") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tab") ?? 0,
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM tab
                        WHERE spaceId IS NULL OR spaceId = ''
                           OR spaceId NOT IN (SELECT id FROM space)
                        """
                ) ?? 0
            )
        }

        // No user data is deleted by a migration, ever (7.2).
        #expect(tabCount == 3)
        #expect(spaceCount == 1)
        #expect(orphanCount == 0)
    }

    @Test("v2 on an empty v1 profile still creates the default Space")
    func v2OnEmptyProfile() throws {
        let queue = try v1Fixture(tabCount: 0)

        try Migrations.makeMigrator().migrate(queue)

        let spaceCount = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM space") ?? 0
        }
        #expect(spaceCount == 1)
    }

    @Test("The generated Space has a usable data store identifier")
    func generatedSpaceIsUsable() throws {
        let queue = try v1Fixture(tabCount: 1)
        try Migrations.makeMigrator().migrate(queue)

        let row = try queue.read { db in try SpaceRow.fetchOne(db) }
        let space = try #require(row.flatMap(SpaceMapping.model(from:)))

        #expect(!space.name.isEmpty)
        #expect(space.gradient.count == 2)
        #expect(!space.isPrivate)
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
                spaceId: UUID().uuidString,
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

    @Test("v6 adopts existing global history into the first Space, deleting nothing")
    func v6AdoptsHistoryIntoFirstSpace() throws {
        let queue = try DatabaseQueue()
        let migrator = Migrations.makeMigrator()
        // Stop at v5, where historyEntry is still the global (url-unique) shape.
        try migrator.migrate(queue, upTo: "v5_granted_permissions")

        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO historyEntry (id, url, title, lastVisitedAt, visitCount)
                    VALUES (?, 'https://kept.example', 'Kept', 123, 2)
                    """,
                arguments: [UUID().uuidString]
            )
        }

        // Finish migrating to v6.
        try migrator.migrate(queue)

        let (firstSpaceID, rowSpaceID, count, visitCount) = try queue.read { db in
            (
                try String.fetchOne(db, sql: "SELECT id FROM space ORDER BY sortIndex LIMIT 1"),
                try String.fetchOne(
                    db, sql: "SELECT spaceId FROM historyEntry WHERE url = 'https://kept.example'"
                ),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM historyEntry") ?? 0,
                try Int.fetchOne(
                    db, sql: "SELECT visitCount FROM historyEntry WHERE url = 'https://kept.example'"
                ) ?? 0
            )
        }

        #expect(count == 1, "history is not deleted by the migration (7.2)")
        #expect(rowSpaceID == firstSpaceID, "adopted into the first Space")
        #expect(visitCount == 2, "the visit count is carried across")
    }

    @Test("After v6 the same URL can live in two Spaces")
    func v6AllowsSameURLPerSpace() throws {
        let queue = try DatabaseQueue()
        try Migrations.makeMigrator().migrate(queue)

        try queue.write { db in
            for space in ["space-a", "space-b"] {
                try db.execute(
                    sql: """
                        INSERT INTO historyEntry (id, url, spaceId, title, lastVisitedAt, visitCount)
                        VALUES (?, 'https://dup.example', ?, 'Dup', 0, 1)
                        """,
                    arguments: [UUID().uuidString, space]
                )
            }
        }

        let count = try queue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM historyEntry WHERE url = 'https://dup.example'"
            ) ?? 0
        }
        #expect(count == 2)
    }

    @Test("v7 adds the folder table and a nullable folderId, deleting nothing")
    func v7AddsFolders() throws {
        let queue = try DatabaseQueue()
        let migrator = Migrations.makeMigrator()
        try migrator.migrate(queue, upTo: "v6_history_per_space")

        // A pre-v7 tab, to prove the additive column leaves it untouched.
        let tabID = UUID().uuidString
        let spaceID = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM space ORDER BY sortIndex LIMIT 1")
        } ?? UUID().uuidString
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO tab
                        (id, spaceId, placementKind, placementOrder, focusedPaneID,
                         lastAccessedAt, createdAt)
                    VALUES (?, ?, 'ephemeral', 0, ?, 0, 0)
                    """,
                arguments: [tabID, spaceID, UUID().uuidString]
            )
        }

        try migrator.migrate(queue)

        let (hasFolder, tabCount, folderId) = try queue.read { db in
            (
                try db.tableExists("folder"),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tab") ?? 0,
                try String.fetchOne(db, sql: "SELECT folderId FROM tab WHERE id = ?", arguments: [tabID])
            )
        }
        #expect(hasFolder)
        #expect(tabCount == 1, "the existing tab is not deleted")
        #expect(folderId == nil, "existing tabs default to no folder")
    }

    @Test("v8 adds a nullable pinnedHomeURL, deleting nothing")
    func v8AddsPinnedHomeURL() throws {
        let queue = try DatabaseQueue()
        let migrator = Migrations.makeMigrator()
        try migrator.migrate(queue, upTo: "v7_folders")

        // A pre-v8 tab, to prove the additive column leaves it untouched.
        let tabID = UUID().uuidString
        let spaceID = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM space ORDER BY sortIndex LIMIT 1")
        } ?? UUID().uuidString
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO tab
                        (id, spaceId, placementKind, placementOrder, focusedPaneID,
                         lastAccessedAt, createdAt)
                    VALUES (?, ?, 'ephemeral', 0, ?, 0, 0)
                    """,
                arguments: [tabID, spaceID, UUID().uuidString]
            )
        }

        try migrator.migrate(queue)

        let (tabCount, homeURL) = try queue.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tab") ?? 0,
                try String.fetchOne(
                    db, sql: "SELECT pinnedHomeURL FROM tab WHERE id = ?", arguments: [tabID]
                )
            )
        }
        #expect(tabCount == 1, "the existing tab is not deleted")
        #expect(homeURL == nil, "existing tabs have no pinned home URL")
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
