import BrowserCore
import Foundation
import GRDB

/// The on-disk shape of one window's layout (v9). Nullable references are plain
/// text with no foreign key, so a Space or tab that vanished between sessions
/// leaves a row that simply fails to resolve — the window reconciles rather than
/// the load failing.
struct WindowLayoutRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "windowLayout"

    var ordinal: Int
    var activeSpaceId: String?
    var selectedTabId: String?
}

/// Per-window layout persistence (v9, non-spec: user-requested). The whole set is
/// replaced on each save — the windows open now *are* the layout — mirroring how
/// `SQLiteTabRepository.save` reinserts wholesale rather than diffing. Writes go
/// through the database's serial queue like all other persistence (6.5).
public struct SQLiteWindowLayoutRepository: WindowLayoutRepository {
    private let database: BrowserDatabase

    public init(database: BrowserDatabase) {
        self.database = database
    }

    public func loadWindowLayouts() async throws -> [WindowLayout] {
        try await database.writer.read { db in
            try WindowLayoutRow
                .order(Column("ordinal"))
                .fetchAll(db)
                .map { row in
                    WindowLayout(
                        ordinal: row.ordinal,
                        activeSpaceID: row.activeSpaceId.flatMap(UUID.init(uuidString:)),
                        selectedTabID: row.selectedTabId.flatMap(UUID.init(uuidString:))
                    )
                }
        }
    }

    public func saveWindowLayouts(_ layouts: [WindowLayout]) async throws {
        try await database.writer.write { db in
            try WindowLayoutRow.deleteAll(db)
            for layout in layouts {
                try WindowLayoutRow(
                    ordinal: layout.ordinal,
                    activeSpaceId: layout.activeSpaceID?.uuidString,
                    selectedTabId: layout.selectedTabID?.uuidString
                ).insert(db)
            }
        }
    }
}
