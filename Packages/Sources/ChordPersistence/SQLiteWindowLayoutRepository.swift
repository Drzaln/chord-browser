import ChordCore
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
    /// Comma-joined UUID strings (v15). NULL for a pre-v15 row.
    var blankSpaceIds: String?
}

/// Per-window layout persistence (v9, non-spec: user-requested). The whole set is
/// replaced on each save — the windows open now *are* the layout — mirroring how
/// `SQLiteTabRepository.save` reinserts wholesale rather than diffing. Writes go
/// through the database's serial queue like all other persistence (6.5).
public struct SQLiteWindowLayoutRepository: WindowLayoutRepository {
    private let database: ChordDatabase

    public init(database: ChordDatabase) {
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
                        selectedTabID: row.selectedTabId.flatMap(UUID.init(uuidString:)),
                        blankSpaceIDs: Self.decodeBlankSpaces(row.blankSpaceIds)
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
                    selectedTabId: layout.selectedTabID?.uuidString,
                    blankSpaceIds: Self.encodeBlankSpaces(layout.blankSpaceIDs)
                ).insert(db)
            }
        }
    }

    /// A stable, human-readable encoding: sorted UUID strings, comma-joined.
    /// `nil` when empty, so a window with no blank Spaces keeps the pre-v15 shape.
    static func encodeBlankSpaces(_ ids: Set<UUID>) -> String? {
        ids.isEmpty ? nil : ids.map(\.uuidString).sorted().joined(separator: ",")
    }

    static func decodeBlankSpaces(_ raw: String?) -> Set<UUID> {
        guard let raw, !raw.isEmpty else { return [] }
        return Set(raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }
}
