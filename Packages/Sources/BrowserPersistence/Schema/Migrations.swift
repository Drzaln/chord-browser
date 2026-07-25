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
        migrator.registerMigration("v3_history_and_archive", migrate: v3HistoryAndArchive)
        migrator.registerMigration("v4_extension_enablement", migrate: v4ExtensionEnablement)
        migrator.registerMigration("v5_granted_permissions", migrate: v5GrantedPermissions)
        migrator.registerMigration("v6_history_per_space", migrate: v6HistoryPerSpace)
        return migrator
    }

    /// Current schema version, bumped alongside each registered migration.
    static let currentVersion = 6

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

    /// Adds history and the ephemeral-tab archive (M3).
    ///
    /// History is title and URL only — full-text search over page content was
    /// considered and declined (ADR 007). Adding FTS later is a new table and a
    /// new migration, not a reshape of this one.
    private static func v3HistoryAndArchive(_ db: Database) throws {
        try db.create(table: "historyEntry") { t in
            t.primaryKey("id", .text).notNull()
            // Unique so a visit is an upsert: one row per page, with a count.
            t.column("url", .text).notNull().unique()
            t.column("title", .text).notNull()
            t.column("lastVisitedAt", .double).notNull()
            t.column("visitCount", .integer).notNull().defaults(to: 1)
        }
        try db.create(indexOn: "historyEntry", columns: ["lastVisitedAt"])

        try db.create(table: "archivedTab") { t in
            t.primaryKey("id", .text).notNull()
            t.column("url", .text).notNull()
            t.column("title", .text).notNull()
            t.column("faviconData", .blob)
            t.column("spaceId", .text).notNull()
            t.column("archivedAt", .double).notNull()
        }
        try db.create(indexOn: "archivedTab", columns: ["archivedAt"])
    }

    /// Adds per-Space extension enablement (M7, 7.4).
    ///
    /// Presence of a row means the extension is enabled in that Space; disabling
    /// deletes the row. Keyed by (spaceId, slug); the row goes when its Space is
    /// deleted (cascade), since an enablement for a Space that no longer exists
    /// is meaningless. Purely additive — no existing data is touched (7.2).
    private static func v4ExtensionEnablement(_ db: Database) throws {
        try db.create(table: "extensionEnablement") { t in
            t.column("spaceId", .text).notNull()
                .references("space", onDelete: .cascade)
            t.column("slug", .text).notNull()
            t.primaryKey(["spaceId", "slug"])
        }
    }

    /// M7 7.5c: per-(Space, extension) permission grants. Additive, like v4 —
    /// nothing existing is touched. `spaceId` cascades from `space` so deleting a
    /// Space reclaims its grants, matching `extensionEnablement`. The full tuple
    /// is the primary key, so re-granting the same thing is idempotent.
    private static func v5GrantedPermissions(_ db: Database) throws {
        try db.create(table: "grantedPermission") { t in
            t.column("spaceId", .text).notNull()
                .references("space", onDelete: .cascade)
            t.column("slug", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("value", .text).notNull()
            t.primaryKey(["spaceId", "slug", "kind", "value"])
        }
    }

    /// Scopes history to a Space, matching the per-Space isolation the data
    /// stores already give cookies and logins (non-spec: user-requested).
    ///
    /// The v3 table keyed uniqueness on `url` alone, so a page could exist only
    /// once across the whole profile; per-Space needs uniqueness on
    /// `(url, spaceId)`. SQLite can't drop a column's UNIQUE in place, so the
    /// table is rebuilt. Existing rows are adopted into the first Space (lowest
    /// `sortIndex`) rather than dropped — no history is deleted (7.2). A profile
    /// with no Space yet keeps them under the empty sentinel, which the store
    /// never queries, so they are orphaned-not-lost per the migration rules.
    private static func v6HistoryPerSpace(_ db: Database) throws {
        let defaultSpaceID = try String.fetchOne(
            db, sql: "SELECT id FROM space ORDER BY sortIndex LIMIT 1"
        ) ?? ""

        try db.create(table: "historyEntry_new") { t in
            t.primaryKey("id", .text).notNull()
            t.column("url", .text).notNull()
            t.column("spaceId", .text).notNull().defaults(to: "")
            t.column("title", .text).notNull()
            t.column("lastVisitedAt", .double).notNull()
            t.column("visitCount", .integer).notNull().defaults(to: 1)
            // One row per page *per Space*: a visit is an upsert within a Space.
            t.uniqueKey(["url", "spaceId"])
        }

        try db.execute(
            sql: """
                INSERT INTO historyEntry_new
                    (id, url, spaceId, title, lastVisitedAt, visitCount)
                SELECT id, url, ?, title, lastVisitedAt, visitCount FROM historyEntry
                """,
            arguments: [defaultSpaceID]
        )

        try db.drop(table: "historyEntry")
        try db.rename(table: "historyEntry_new", to: "historyEntry")
        try db.create(indexOn: "historyEntry", columns: ["spaceId", "lastVisitedAt"])
    }
}
