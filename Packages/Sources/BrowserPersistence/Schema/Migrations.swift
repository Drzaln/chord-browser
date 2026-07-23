import Foundation
import GRDB

/// Sequential, forward-only, individually named migrations (BROWSER_SPEC 7.2).
///
/// Rules that hold for every migration added here, forever:
///   - never delete user data; orphan it and log
///   - each migration gets a test that runs it against a fixture database
///     captured from the *previous* version, kept in the repo permanently
///   - never renumber or edit a shipped migration
enum Migrations {
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // Registered at v1 from day one, before anything has changed, because
        // retrofitting versioning later is the painful path.
        migrator.registerMigration("v1_initial", migrate: v1Initial)
        migrator.registerMigration("v2_add_spaces", migrate: v2AddSpaces)
        return migrator
    }

    /// Current schema version, bumped alongside each registered migration.
    static let currentVersion = 2

    /// Exposed so migration tests can build a fixture database at exactly v1,
    /// which is what every later migration must be tested against (7.2).
    static func v1ForTesting(_ db: Database) throws {
        try v1Initial(db)
    }

    private static func v1Initial(_ db: Database) throws {
        try db.create(table: "tab") { t in
            t.primaryKey("id", .text).notNull()
            t.column("placementKind", .text).notNull()      // "pinned" | "ephemeral"
            t.column("placementOrder", .integer).notNull()
            t.column("focusedPaneID", .text).notNull()
            t.column("lastAccessedAt", .double).notNull()
            t.column("createdAt", .double).notNull()
        }
        try db.create(
            indexOn: "tab", columns: ["placementKind", "placementOrder"]
        )

        try db.create(table: "pane") { t in
            t.primaryKey("id", .text).notNull()
            t.belongsTo("tab", onDelete: .cascade).notNull()
            t.column("position", .integer).notNull()
            t.column("url", .text).notNull()
            t.column("title", .text).notNull()
            t.column("faviconData", .blob)
            t.column("widthFraction", .double).notNull()
        }
        try db.create(indexOn: "pane", columns: ["tabId", "position"])

        // interactionState blobs are large and read rarely, so they live in
        // their own table and are never joined into a tab list load (6.5).
        try db.create(table: "paneInteractionState") { t in
            t.primaryKey("paneId", .text).notNull()
            t.column("data", .blob).notNull()
            t.column("updatedAt", .double).notNull()
        }
    }

    /// Adds Spaces (M2).
    ///
    /// Additive by design: existing tabs are adopted by a generated default
    /// Space rather than being dropped or rewritten. Nothing the user had is
    /// deleted, which is the rule every migration here follows (7.2).
    private static func v2AddSpaces(_ db: Database) throws {
        try db.create(table: "space") { t in
            t.primaryKey("id", .text).notNull()
            t.column("name", .text).notNull()
            t.column("iconSymbol", .text).notNull()
            t.column("gradient", .text).notNull()      // comma-separated hex stops
            t.column("dataStoreID", .text).notNull()
            t.column("sortIndex", .integer).notNull()
            t.column("isPrivate", .boolean).notNull().defaults(to: false)
        }

        // A v1 profile has tabs but no Space to hang them on, so one is created
        // here and every existing tab is adopted into it.
        let defaultSpaceID = UUID().uuidString
        try db.execute(
            sql: """
                INSERT INTO space
                    (id, name, iconSymbol, gradient, dataStoreID, sortIndex, isPrivate)
                VALUES (?, ?, ?, ?, ?, 0, 0)
                """,
            arguments: [
                defaultSpaceID,
                "Personal",
                "person",
                "#5B7FFF,#8E6BFF",
                UUID().uuidString,
            ]
        )

        try db.alter(table: "tab") { t in
            t.add(column: "spaceId", .text).notNull().defaults(to: "")
        }
        try db.execute(
            sql: "UPDATE tab SET spaceId = ? WHERE spaceId = ''",
            arguments: [defaultSpaceID]
        )
        try db.create(indexOn: "tab", columns: ["spaceId", "placementOrder"])
    }
}
