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
        return migrator
    }

    /// Current schema version, bumped alongside each registered migration.
    static let currentVersion = 1

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
}
