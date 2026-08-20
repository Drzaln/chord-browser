import ChordCore
import Foundation

/// An offer to save or update a login, awaiting the user's answer (V5 of the
/// vault — `docs/design/password-vault.md`).
///
/// **The password is deliberately not here.** This is the value the UI binds to,
/// and it ends up in an `@Observable` store, in view bodies, and in any debug
/// description of either. The secret stays in a private side table in `TabStore`
/// keyed by `id`, so a `print(store)` or a crash log cannot contain it.
public struct CredentialSavePrompt: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// The origin the credential belongs to, canonical.
    public let origin: String
    /// The host alone, for the bar's copy.
    public let host: String
    public let username: String
    /// Whether this replaces a password already saved for this login — the bar
    /// says "Update" rather than "Save", because overwriting a working password
    /// by accident is worse than declining to save a new one.
    public let isUpdate: Bool

    public init(
        id: UUID = UUID(), origin: String, host: String, username: String, isUpdate: Bool
    ) {
        self.id = id
        self.origin = origin
        self.host = host
        self.username = username
        self.isUpdate = isUpdate
    }
}

/// How the user answered the save bar.
public enum CredentialSaveDecision: Equatable, Sendable {
    /// Save it (or update the existing one).
    case save
    /// Not this time. The same login may be offered again later.
    case dismiss
    /// Never offer for this site again — remembered in `credentialNeverSave`.
    case never
}
