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
        migrator.registerMigration("v7_folders", migrate: v7Folders)
        migrator.registerMigration("v8_pinned_home_url", migrate: v8PinnedHomeURL)
        migrator.registerMigration("v9_window_layout", migrate: v9WindowLayout)
        migrator.registerMigration("v10_site_permissions", migrate: v10SitePermissions)
        migrator.registerMigration(
            "v11_site_permissions_per_space", migrate: v11SitePermissionsPerSpace
        )
        migrator.registerMigration("v12_credentials", migrate: v12Credentials)
        migrator.registerMigration("v13_credential_never_save", migrate: v13CredentialNeverSave)
        return migrator
    }

    /// Current schema version, bumped alongside each registered migration.
    static let currentVersion = 13

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
    /// Per-origin camera/microphone decisions (non-spec: user-requested),
    /// replacing the old blanket auto-grant with ask-once-per-site. Global here;
    /// v11 re-scopes it to a Space. Additive; deletes nothing.
    private static func v10SitePermissions(_ db: Database) throws {
        try db.create(table: "sitePermission") { t in
            t.column("origin", .text).notNull()
            t.column("device", .text).notNull()
            t.column("decision", .text).notNull()
            t.primaryKey(["origin", "device"])
        }
    }

    /// Re-scopes site camera/mic permissions to a Space (ADR 006, ADR 011), to
    /// match the isolation cookies, storage, and extension grants already have.
    ///
    /// The v10 table keyed on `origin` alone; per-Space needs `(spaceId, origin,
    /// device)`. SQLite can't add a PK column in place, so the table is rebuilt.
    /// Existing rows are adopted into the first Space (lowest `sortIndex`) rather
    /// than dropped — no decision is deleted (7.2), the same adoption v6 did for
    /// history. A profile with no Space yet keeps nothing to adopt.
    private static func v11SitePermissionsPerSpace(_ db: Database) throws {
        let defaultSpaceID = try String.fetchOne(
            db, sql: "SELECT id FROM space ORDER BY sortIndex LIMIT 1"
        ) ?? ""

        try db.create(table: "sitePermission_new") { t in
            t.column("spaceId", .text).notNull()
                .references("space", onDelete: .cascade)
            t.column("origin", .text).notNull()
            t.column("device", .text).notNull()
            t.column("decision", .text).notNull()
            t.primaryKey(["spaceId", "origin", "device"])
        }
        if !defaultSpaceID.isEmpty {
            try db.execute(
                sql: """
                    INSERT INTO sitePermission_new (spaceId, origin, device, decision)
                    SELECT ?, origin, device, decision FROM sitePermission
                    """,
                arguments: [defaultSpaceID]
            )
        }
        try db.drop(table: "sitePermission")
        try db.rename(table: "sitePermission_new", to: "sitePermission")
    }

    /// The password vault's **metadata** half (V2 — docs/design/password-vault.md).
    ///
    /// What is deliberately *not* here: the password. Secrets live in the
    /// Keychain, reached only through `BrowserSecrets`, joined to these rows by
    /// `id`. That split is the reason a database backup, a `.recover` dump, or a
    /// stray `sqlite3` session can never contain a credential.
    ///
    /// `lastUsedSpaceId` is a *hint* for ordering the picker (offer the account
    /// you last used in this Space first), not ownership — the vault is global by
    /// design, so this **nulls** rather than cascades when a Space is deleted.
    /// Deleting a Space must never delete a password.
    ///
    /// `(origin, username)` is unique: saving the same login twice updates it
    /// rather than growing a duplicate the picker would show twice.
    private static func v12Credentials(_ db: Database) throws {
        try db.create(table: "credential") { t in
            t.primaryKey("id", .text)
            t.column("origin", .text).notNull()
            t.column("username", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("lastUsedAt", .datetime)
            t.column("lastUsedSpaceId", .text)
                .references("space", onDelete: .setNull)
            t.uniqueKey(["origin", "username"])
        }
        // The lookup on every page load with a login form: by origin.
        try db.create(index: "credential_origin", on: "credential", columns: ["origin"])
    }

    /// "Never save passwords for this site" (V5 of the vault).
    ///
    /// Its own table rather than a column on `credential`, because the decision
    /// exists precisely when there is **no** credential to hang it on. Global,
    /// not per-Space: "do not offer to save here" is a statement about the site,
    /// not about which identity you are using — unlike the camera and microphone
    /// grants of ADR 014, which are about what a site may *do* to you.
    private static func v13CredentialNeverSave(_ db: Database) throws {
        try db.create(table: "credentialNeverSave") { t in
            t.primaryKey("origin", .text)
        }
    }

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

    /// Sidebar folders (non-spec: user-requested). Purely additive — a new table
    /// plus a nullable `folderId` on `tab`, defaulting to NULL so every existing
    /// tab is simply "not in a folder" (7.2). Deleting a Space cascades its
    /// folders; the tab's own `folderId` has no FK so a deleted folder just
    /// leaves its tabs loose (the store nulls them).
    private static func v7Folders(_ db: Database) throws {
        try db.create(table: "folder") { t in
            t.primaryKey("id", .text).notNull()
            t.column("spaceId", .text).notNull()
                .references("space", onDelete: .cascade)
            t.column("name", .text).notNull()
            t.column("sortIndex", .integer).notNull()
            t.column("isCollapsed", .boolean).notNull().defaults(to: false)
        }
        try db.create(indexOn: "folder", columns: ["spaceId", "sortIndex"])

        try db.alter(table: "tab") { t in
            t.add(column: "folderId", .text)
        }
    }

    /// Arc-style *Pinned* tabs (non-spec: user-requested). Purely additive — a
    /// nullable `pinnedHomeURL` on `tab`, defaulting to NULL so every existing
    /// tab is unaffected (7.2). The tier itself is carried in the existing
    /// `placementKind` column as the new value "bookmarked"; only Pinned tabs
    /// set the URL column.
    private static func v8PinnedHomeURL(_ db: Database) throws {
        try db.alter(table: "tab") { t in
            t.add(column: "pinnedHomeURL", .text)
        }
    }

    /// Per-window layout, so a relaunch restores which Space and tab each window
    /// showed rather than reconciling every one to a default (non-spec:
    /// user-requested). Purely additive — a new table only, nothing existing is
    /// touched (7.2). One row per open window, keyed by its ordinal in window
    /// order (the primary at 0); `activeSpaceId` / `selectedTabId` are nullable
    /// because a window can legitimately have neither yet, and are plain columns
    /// with no foreign key so a Space or tab that vanishes between sessions simply
    /// fails to resolve and the window reconciles — orphaned, never a failed load.
    private static func v9WindowLayout(_ db: Database) throws {
        try db.create(table: "windowLayout") { t in
            t.primaryKey("ordinal", .integer).notNull()
            t.column("activeSpaceId", .text)
            t.column("selectedTabId", .text)
        }
    }
}
