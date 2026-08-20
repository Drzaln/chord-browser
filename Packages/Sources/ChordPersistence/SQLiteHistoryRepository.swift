import ChordCore
import Foundation
import GRDB

struct HistoryRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "historyEntry"

    var id: String
    var url: String
    var spaceId: String
    var title: String
    var lastVisitedAt: Double
    var visitCount: Int
}

struct ArchivedTabRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "archivedTab"

    var id: String
    var url: String
    var title: String
    /// The user's own name for the tab, or nil (non-spec: user-requested).
    var customTitle: String?
    var faviconData: Data?
    var spaceId: String
    var archivedAt: Double
}

public struct SQLiteHistoryRepository: HistoryRepository, ArchiveRepository {
    private let database: ChordDatabase

    public init(database: ChordDatabase) {
        self.database = database
    }

    // MARK: - History

    /// One row per URL: revisiting bumps the count and the timestamp rather
    /// than growing the table. History writes go through the database's own
    /// serial queue, never the main thread (6.5).
    public func recordVisit(url: URL, title: String, spaceID: UUID, at date: Date) async throws {
        let key = url.absoluteString
        let space = spaceID.uuidString
        try await database.writer.write { db in
            if var existing = try HistoryRow
                .filter(Column("url") == key && Column("spaceId") == space)
                .fetchOne(db)
            {
                existing.visitCount += 1
                existing.lastVisitedAt = date.timeIntervalSince1970
                if !title.isEmpty { existing.title = title }
                try existing.update(db)
            } else {
                try HistoryRow(
                    id: UUID().uuidString,
                    url: key,
                    spaceId: space,
                    title: title,
                    lastVisitedAt: date.timeIntervalSince1970,
                    visitCount: 1
                ).insert(db)
            }
        }
    }

    /// Deletes every history row in every Space. Runs on the database's serial
    /// queue, off the main thread (6.5), like every other write here.
    public func deleteAllHistory() async throws {
        try await database.writer.write { db in
            _ = try HistoryRow.deleteAll(db)
        }
    }

    /// Deletes every history row in one Space.
    public func deleteAllHistory(inSpace spaceID: UUID) async throws {
        let space = spaceID.uuidString
        try await database.writer.write { db in
            _ = try HistoryRow.filter(Column("spaceId") == space).deleteAll(db)
        }
    }

    /// Deletes the rows with the given ids. Runs on the database's serial queue,
    /// off the main thread (6.5). A no-op for an empty list.
    public func deleteHistory(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        let keys = ids.map(\.uuidString)
        try await database.writer.write { db in
            _ = try HistoryRow.filter(keys.contains(Column("id"))).deleteAll(db)
        }
    }

    public func recentHistory(inSpace spaceID: UUID, limit: Int) async throws -> [HistoryEntry] {
        let space = spaceID.uuidString
        return try await database.writer.read { db in
            let rows = try HistoryRow
                .filter(Column("spaceId") == space)
                .order(Column("lastVisitedAt").desc)
                .limit(limit)
                .fetchAll(db)

            return rows.compactMap { row -> HistoryEntry? in
                guard let id = UUID(uuidString: row.id), let url = URL(string: row.url) else {
                    Log.db.error("skipping unparseable history row")
                    return nil
                }
                return HistoryEntry(
                    id: id,
                    url: url,
                    title: row.title,
                    lastVisitedAt: Date(timeIntervalSince1970: row.lastVisitedAt),
                    visitCount: row.visitCount
                )
            }
        }
    }

    // MARK: - Archive

    /// Appends, then trims to the newest `archiveLimit`. The sweep never
    /// hard-deletes; this cap is the only thing that removes rows (4.3).
    public func archive(_ tabs: [ArchivedTab]) async throws {
        guard !tabs.isEmpty else { return }

        try await database.writer.write { db in
            for tab in tabs {
                try ArchivedTabRow(
                    id: tab.id.uuidString,
                    url: tab.url.absoluteString,
                    title: tab.title,
                    customTitle: tab.customTitle,
                    faviconData: tab.faviconData,
                    spaceId: tab.spaceID.uuidString,
                    archivedAt: tab.archivedAt.timeIntervalSince1970
                ).insert(db)
            }

            try db.execute(
                sql: """
                    DELETE FROM archivedTab
                    WHERE id NOT IN (
                        SELECT id FROM archivedTab ORDER BY archivedAt DESC LIMIT ?
                    )
                    """,
                arguments: [SweepPolicy.archiveLimit]
            )
        }
    }

    public func archivedTabs() async throws -> [ArchivedTab] {
        try await database.writer.read { db in
            let rows = try ArchivedTabRow
                .order(Column("archivedAt").desc)
                .fetchAll(db)

            return rows.compactMap { row -> ArchivedTab? in
                guard let id = UUID(uuidString: row.id),
                      let url = URL(string: row.url),
                      let spaceID = UUID(uuidString: row.spaceId)
                else {
                    Log.db.error("skipping unparseable archived tab row")
                    return nil
                }
                return ArchivedTab(
                    id: id,
                    url: url,
                    title: row.title,
                    customTitle: row.customTitle,
                    faviconData: row.faviconData,
                    spaceID: spaceID,
                    archivedAt: Date(timeIntervalSince1970: row.archivedAt)
                )
            }
        }
    }
}
