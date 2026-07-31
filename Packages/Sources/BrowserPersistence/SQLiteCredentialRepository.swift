import BrowserCore
import Foundation
import GRDB

/// The stored shape of a credential's metadata. A row type with a mapper, not
/// the `Codable` model — renaming a field on `Credential` must never break an
/// existing vault (§7.2).
struct CredentialRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "credential"

    var id: String
    var origin: String
    var username: String
    var createdAt: Date
    var lastUsedAt: Date?
    var lastUsedSpaceId: String?

    init(_ credential: Credential) {
        id = credential.id.uuidString
        origin = credential.origin
        username = credential.username
        createdAt = credential.createdAt
        lastUsedAt = credential.lastUsedAt
        lastUsedSpaceId = credential.lastUsedSpaceID?.uuidString
    }

    /// Nil for a row that cannot be trusted. Decoding is defensive by rule
    /// (§3.7): a corrupt row costs one credential, never a launch — and in this
    /// subsystem, never a fill against a garbled origin.
    var credential: Credential? {
        guard let uuid = UUID(uuidString: id), !origin.isEmpty else { return nil }
        return Credential(
            id: uuid,
            origin: origin,
            username: username,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            lastUsedSpaceID: lastUsedSpaceId.flatMap(UUID.init(uuidString:))
        )
    }
}

/// The vault's metadata store (V2 — `docs/design/password-vault.md`).
///
/// **No password passes through here.** Secrets live in the Keychain behind
/// `BrowserSecrets`; this table holds only which site, which username, and when
/// it was last used. Writes go through the database's serial queue like all other
/// persistence, never the main thread (§6.5).
public struct SQLiteCredentialRepository: CredentialRepository {
    private let database: BrowserDatabase

    public init(database: BrowserDatabase) {
        self.database = database
    }

    public func credentials(forOrigin origin: String, spaceID: UUID?) async throws -> [Credential] {
        try await database.writer.read { db in
            let rows = try CredentialRow
                .filter(Column("origin") == origin)
                .fetchAll(db)
            return Self.ordered(rows.compactMap(\.credential), forSpace: spaceID)
        }
    }

    public func all() async throws -> [Credential] {
        try await database.writer.read { db in
            try CredentialRow
                .order(Column("origin"), Column("username"))
                .fetchAll(db)
                .compactMap(\.credential)
        }
    }

    @discardableResult
    public func upsert(_ credential: Credential) async throws -> Credential {
        try await database.writer.write { db in
            // Keep the existing id on a collision, so the caller's secret write
            // lands on the row that already owns a Keychain item instead of
            // orphaning one.
            let existing = try CredentialRow
                .filter(
                    Column("origin") == credential.origin
                        && Column("username") == credential.username
                )
                .fetchOne(db)?
                .credential

            var stored = credential
            if let existing {
                stored = Credential(
                    id: existing.id,
                    origin: existing.origin,
                    username: credential.username,
                    createdAt: existing.createdAt,
                    lastUsedAt: credential.lastUsedAt ?? existing.lastUsedAt,
                    lastUsedSpaceID: credential.lastUsedSpaceID ?? existing.lastUsedSpaceID
                )
            }
            try CredentialRow(stored).insert(db, onConflict: .replace)
            return stored
        }
    }

    public func markUsed(id: UUID, at date: Date, inSpace spaceID: UUID?) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE credential SET lastUsedAt = ?, lastUsedSpaceId = ?
                    WHERE id = ?
                    """,
                arguments: [date, spaceID?.uuidString, id.uuidString]
            )
        }
    }

    public func delete(id: UUID) async throws {
        try await database.writer.write { db in
            _ = try CredentialRow.filter(Column("id") == id.uuidString).deleteAll(db)
        }
    }

    public func storedIDs() async throws -> Set<UUID> {
        try await database.writer.read { db in
            Set(try CredentialRow.fetchAll(db).compactMap(\.credential).map(\.id))
        }
    }

    /// Picker order: the account last used *in this Space* first, then whatever
    /// was used most recently anywhere, then by username so the list never
    /// reshuffles between identical states.
    ///
    /// Static and pure so the rule is testable without a database.
    static func ordered(_ credentials: [Credential], forSpace spaceID: UUID?) -> [Credential] {
        credentials.sorted { lhs, rhs in
            let lhsHere = spaceID != nil && lhs.lastUsedSpaceID == spaceID
            let rhsHere = spaceID != nil && rhs.lastUsedSpaceID == spaceID
            if lhsHere != rhsHere { return lhsHere }

            switch (lhs.lastUsedAt, rhs.lastUsedAt) {
            case let (l?, r?) where l != r: return l > r
            case (nil, .some): return false
            case (.some, nil): return true
            default: return lhs.username < rhs.username
            }
        }
    }
}
