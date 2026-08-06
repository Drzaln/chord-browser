import BrowserCore
import Foundation
import GRDB

public struct SQLiteTabRepository: TabRepository, SpaceRepository, FolderRepository {
    private let database: BrowserDatabase

    public init(database: BrowserDatabase) {
        self.database = database
    }

    public func loadAll() async throws -> [Tab] {
        try await database.writer.read { db in
            let tabRows = try TabRow
                .order(Column("placementOrder"))
                .fetchAll(db)
            let paneRows = try PaneRow.fetchAll(db)
            let panesByTab = Dictionary(grouping: paneRows, by: \.tabId)

            let tabs = tabRows.compactMap { row in
                TabMapping.model(tabRow: row, paneRows: panesByTab[row.id] ?? [])
            }
            if tabs.count != tabRows.count {
                Log.db.error(
                    "dropped \(tabRows.count - tabs.count) corrupt tab row(s)"
                )
            }
            return tabs
        }
    }

    /// Full replace. The tab set is small and this runs debounced (~2s), so the
    /// simplicity is worth more than a differential write here.
    public func save(_ tabs: [Tab]) async throws {
        try await database.writer.write { db in
            try TabRow.deleteAll(db)  // panes cascade
            for tab in tabs {
                let (tabRow, paneRows) = TabMapping.rows(for: tab)
                try tabRow.insert(db)
                for pane in paneRows { try pane.insert(db) }
            }
        }
    }

    // MARK: - Spaces

    public func loadSpaces() async throws -> [Space] {
        try await database.writer.read { db in
            let rows = try SpaceRow.order(Column("sortIndex")).fetchAll(db)
            let spaces = rows.compactMap(SpaceMapping.model(from:))
            if spaces.count != rows.count {
                Log.db.error(
                    "dropped \(rows.count - spaces.count) corrupt space row(s)"
                )
            }
            return spaces
        }
    }

    public func saveSpaces(_ spaces: [Space]) async throws {
        try await database.writer.write { db in
            try SpaceRow.deleteAll(db)
            for space in spaces {
                try SpaceMapping.row(for: space).insert(db)
            }
        }
    }

    // MARK: - Folders

    public func loadFolders() async throws -> [Folder] {
        try await database.writer.read { db in
            let rows = try FolderRow.order(Column("sortIndex")).fetchAll(db)
            return rows.compactMap { row -> Folder? in
                guard let id = UUID(uuidString: row.id),
                      let spaceID = UUID(uuidString: row.spaceId)
                else {
                    Log.db.error("skipping unparseable folder row")
                    return nil
                }
                return Folder(
                    id: id,
                    spaceID: spaceID,
                    name: row.name,
                    sortIndex: row.sortIndex,
                    isCollapsed: row.isCollapsed
                )
            }
        }
    }

    public func saveFolders(_ folders: [Folder]) async throws {
        try await database.writer.write { db in
            try FolderRow.deleteAll(db)
            for folder in folders {
                try FolderRow(
                    id: folder.id.uuidString,
                    spaceId: folder.spaceID.uuidString,
                    name: folder.name,
                    sortIndex: folder.sortIndex,
                    isCollapsed: folder.isCollapsed
                ).insert(db)
            }
        }
    }

    public func loadInteractionState(paneID: UUID) async throws -> Data? {
        try await database.writer.read { db in
            try PaneInteractionStateRow
                .fetchOne(db, key: paneID.uuidString)?
                .data
        }
    }

    public func saveInteractionState(_ data: Data?, paneID: UUID) async throws {
        try await database.writer.write { db in
            guard let data else {
                _ = try PaneInteractionStateRow.deleteOne(db, key: paneID.uuidString)
                return
            }
            try PaneInteractionStateRow(
                paneId: paneID.uuidString,
                data: data,
                updatedAt: Date().timeIntervalSince1970
            ).upsert(db)
        }
    }

    public func pruneInteractionStates(keeping paneIDs: Set<UUID>) async throws {
        let keep = paneIDs.map(\.uuidString)
        try await database.writer.write { db in
            let deleted = try PaneInteractionStateRow
                .filter(!keep.contains(Column("paneId")))
                .deleteAll(db)
            if deleted > 0 {
                Log.db.debug("pruned \(deleted) orphaned interaction state(s)")
            }
        }
    }
}
