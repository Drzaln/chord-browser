import BrowserCore
import Foundation
import GRDB

struct GrantedPermissionRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "grantedPermission"

    var spaceId: String
    var slug: String
    var kind: String
    var value: String
}

/// Per-(Space, extension) permission grants (M7, 7.5c). We persist grants
/// ourselves and re-apply them on load, rather than relying on WebKit's own
/// storage (a decision recorded in ADR 011 / CHECKPOINT). Writes go through the
/// database's serial queue like all other persistence, never the main thread
/// (6.5).
public struct SQLiteGrantedPermissionsRepository: GrantedPermissionsRepository {
    private let database: BrowserDatabase

    public init(database: BrowserDatabase) {
        self.database = database
    }

    public func granted(slug: String, spaceID: UUID) async throws -> [GrantedPermissionRecord] {
        try await database.writer.read { db in
            try GrantedPermissionRow
                .filter(Column("spaceId") == spaceID.uuidString && Column("slug") == slug)
                .fetchAll(db)
                .compactMap { row in
                    GrantedPermissionKind(rawValue: row.kind).map {
                        GrantedPermissionRecord(
                            spaceID: spaceID, slug: row.slug, kind: $0, value: row.value
                        )
                    }
                }
        }
    }

    public func grant(_ records: [GrantedPermissionRecord]) async throws {
        guard !records.isEmpty else { return }
        try await database.writer.write { db in
            for record in records {
                // Idempotent: the four-column primary key makes a repeat grant a
                // no-op rather than a duplicate.
                try GrantedPermissionRow(
                    spaceId: record.spaceID.uuidString,
                    slug: record.slug,
                    kind: record.kind.rawValue,
                    value: record.value
                ).insert(db, onConflict: .ignore)
            }
        }
    }

    public func revokeAll(slug: String, spaceID: UUID) async throws {
        try await database.writer.write { db in
            _ = try GrantedPermissionRow
                .filter(Column("spaceId") == spaceID.uuidString && Column("slug") == slug)
                .deleteAll(db)
        }
    }
}
