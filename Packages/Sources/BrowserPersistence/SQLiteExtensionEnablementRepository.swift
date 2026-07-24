import BrowserCore
import Foundation
import GRDB

struct ExtensionEnablementRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "extensionEnablement"

    var spaceId: String
    var slug: String
}

/// Per-Space extension enablement (M7, 7.4). Presence of a row means enabled;
/// disabling deletes it. Writes go through the database's serial queue like all
/// other persistence, never the main thread (6.5).
public struct SQLiteExtensionEnablementRepository: ExtensionEnablementRepository {
    private let database: BrowserDatabase

    public init(database: BrowserDatabase) {
        self.database = database
    }

    public func allEnabled() async throws -> [ExtensionEnablementRecord] {
        try await database.writer.read { db in
            try ExtensionEnablementRow.fetchAll(db).compactMap { row in
                UUID(uuidString: row.spaceId).map {
                    ExtensionEnablementRecord(spaceID: $0, slug: row.slug)
                }
            }
        }
    }

    public func enabledSlugs(spaceID: UUID) async throws -> [String] {
        try await database.writer.read { db in
            try ExtensionEnablementRow
                .filter(Column("spaceId") == spaceID.uuidString)
                .fetchAll(db)
                .map(\.slug)
        }
    }

    public func setEnabled(_ enabled: Bool, slug: String, spaceID: UUID) async throws {
        try await database.writer.write { db in
            if enabled {
                // Idempotent insert: the (spaceId, slug) primary key makes a
                // repeat enable a no-op rather than a duplicate.
                try ExtensionEnablementRow(spaceId: spaceID.uuidString, slug: slug)
                    .insert(db, onConflict: .ignore)
            } else {
                try ExtensionEnablementRow
                    .filter(Column("spaceId") == spaceID.uuidString && Column("slug") == slug)
                    .deleteAll(db)
            }
        }
    }
}
