import Foundation

/// Stores the **metadata** half of saved logins — never the password (V2 of the
/// vault). The secret half is `BrowserSecrets.SecretStore`, joined by
/// `Credential.id`.
///
/// Declared here in `BrowserCore`, WebKit-free and Foundation-only, so the Store
/// can depend on the shape and `BrowserPersistence` can implement it — the same
/// arrangement `SitePermissionsRepository` uses.
public protocol CredentialRepository: Sendable {
    /// Credentials saved for an origin, best candidate first.
    ///
    /// Ordering is the picker's ordering, and it is the whole reason
    /// `lastUsedSpaceID` exists: the credential last used *in this Space* comes
    /// first, then the most recently used anywhere, then alphabetically by
    /// username so the list is stable rather than arbitrary. Pass `spaceID` as the
    /// Space the page is in.
    func credentials(forOrigin origin: String, spaceID: UUID?) async throws -> [Credential]

    /// Every saved credential, ordered by origin then username — the Settings
    /// list.
    func all() async throws -> [Credential]

    /// Inserts a credential, or updates the existing one for the same
    /// `(origin, username)`.
    ///
    /// Returns the credential as stored: on a collision the **existing id is
    /// kept**, so the caller writes the secret against an id that already has
    /// one rather than orphaning it. Saving the same login twice must never grow
    /// a second row the picker would show twice.
    @discardableResult
    func upsert(_ credential: Credential) async throws -> Credential

    /// Records that a credential was used, which drives the picker's ordering.
    func markUsed(id: UUID, at date: Date, inSpace spaceID: UUID?) async throws

    /// Deletes one credential's metadata. The caller is responsible for its
    /// secret — `CredentialVault` is what keeps the two in step.
    func delete(id: UUID) async throws

    /// Every stored id, for reconciling against the Keychain: an id here with no
    /// secret, or a secret with no id here, is a bug worth finding.
    func storedIDs() async throws -> Set<UUID>

    // MARK: - "Never save for this site" (V5)

    /// Records that this origin must never be offered a save again.
    func setNeverSave(origin: String) async throws
    /// Whether saving has been declined permanently for an origin.
    func isNeverSave(origin: String) async throws -> Bool
    /// Every origin the user has silenced, for the Settings list.
    func neverSaveOrigins() async throws -> [String]
    /// Un-silences an origin, so it may offer to save again.
    func clearNeverSave(origin: String) async throws
}
