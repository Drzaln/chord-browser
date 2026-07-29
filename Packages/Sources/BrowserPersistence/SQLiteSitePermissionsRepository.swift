import BrowserCore
import Foundation
import GRDB

struct SitePermissionRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "sitePermission"

    var spaceId: String
    var origin: String
    /// The `SitePermissionKind` raw value. Column kept named `device` from the
    /// v10 schema (it predates notifications); the value space just widened.
    var device: String
    var decision: String
}

/// Per-Space, per-origin camera/microphone/notification decisions (non-spec:
/// user-requested). Writes go through the database's serial queue like all other
/// persistence, never the main thread (6.5). Mirrors
/// `SQLiteGrantedPermissionsRepository`.
public struct SQLiteSitePermissionsRepository: SitePermissionsRepository {
    private let database: BrowserDatabase

    public init(database: BrowserDatabase) {
        self.database = database
    }

    public func decisions(
        forOrigin origin: String, spaceID: UUID
    ) async throws -> [SitePermissionKind: SitePermissionDecision] {
        try await database.writer.read { db in
            let rows = try SitePermissionRow
                .filter(Column("spaceId") == spaceID.uuidString && Column("origin") == origin)
                .fetchAll(db)
            var result: [SitePermissionKind: SitePermissionDecision] = [:]
            for row in rows {
                if let kind = SitePermissionKind(rawValue: row.device),
                   let decision = SitePermissionDecision(rawValue: row.decision) {
                    result[kind] = decision
                }
            }
            return result
        }
    }

    public func setDecision(
        _ decision: SitePermissionDecision,
        forOrigin origin: String, spaceID: UUID, kind: SitePermissionKind
    ) async throws {
        try await database.writer.write { db in
            // Overwrite: the newest answer wins, so re-answering a re-prompt
            // updates the record rather than erroring on the three-column key.
            try SitePermissionRow(
                spaceId: spaceID.uuidString,
                origin: origin,
                device: kind.rawValue,
                decision: decision.rawValue
            ).insert(db, onConflict: .replace)
        }
    }

    public func all() async throws -> [SitePermissionRecord] {
        try await database.writer.read { db in
            try SitePermissionRow
                .order(Column("origin"))
                .fetchAll(db)
                .compactMap { row in
                    guard let spaceID = UUID(uuidString: row.spaceId),
                          let kind = SitePermissionKind(rawValue: row.device),
                          let decision = SitePermissionDecision(rawValue: row.decision)
                    else { return nil }
                    return SitePermissionRecord(
                        spaceID: spaceID, origin: row.origin, kind: kind, decision: decision
                    )
                }
        }
    }

    public func revoke(origin: String, spaceID: UUID) async throws {
        try await database.writer.write { db in
            _ = try SitePermissionRow
                .filter(Column("spaceId") == spaceID.uuidString && Column("origin") == origin)
                .deleteAll(db)
        }
    }

    public func clearAll() async throws {
        try await database.writer.write { db in
            _ = try SitePermissionRow.deleteAll(db)
        }
    }
}
