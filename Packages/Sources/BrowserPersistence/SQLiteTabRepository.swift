import BrowserCore
import Foundation
import GRDB

public struct SQLiteTabRepository: TabRepository {
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
                    "dropped \(tabRows.count - tabs.count, privacy: .public) corrupt tab row(s)"
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
}
