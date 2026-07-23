import BrowserCore
import Foundation
import GRDB

struct HistoryRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "historyEntry"

    var id: String
    var url: String
    var title: String
    var lastVisitedAt: Double
    var visitCount: Int
}

struct ArchivedTabRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "archivedTab"

    var id: String
    var url: String
    var title: String
    var faviconData: Data?
    var spaceId: String
    var archivedAt: Double
}

public struct SQLiteHistoryRepository: HistoryRepository, ArchiveRepository {
    private let database: BrowserDatabase

    public init(database: BrowserDatabase) {
        self.database = database
    }

    // MARK: - History

    /// One row per URL: revisiting bumps the count and the timestamp rather
    /// than growing the table. History writes go through the database's own
    /// serial queue, never the main thread (6.5).
    public func recordVisit(url: URL, title: String, at date: Date) async throws {
        let key = url.absoluteString
        try await database.writer.write { db in
            if var existing = try HistoryRow.filter(Column("url") == key).fetchOne(db) {
                existing.visitCount += 1
                existing.lastVisitedAt = date.timeIntervalSince1970
                if !title.isEmpty { existing.title = title }
                try existing.update(db)
            } else {
                try HistoryRow(
                    id: UUID().uuidString,
                    url: key,
                    title: title,
                    lastVisitedAt: date.timeIntervalSince1970,
                    visitCount: 1
                ).insert(db)
            }
        }
    }

    public func recentHistory(limit: Int) async throws -> [HistoryEntry] {
        try await database.writer.read { db in
            let rows = try HistoryRow
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
                    faviconData: row.faviconData,
                    spaceID: spaceID,
                    archivedAt: Date(timeIntervalSince1970: row.archivedAt)
                )
            }
        }
    }
}
