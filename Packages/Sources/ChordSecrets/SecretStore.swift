import Foundation

/// Where a credential's password actually lives.
///
/// A protocol so the layers above never name a Keychain type, and so everything
/// that consumes secrets can be tested against an in-memory double. The real
/// implementation is `KeychainSecretStore`; `ChordSecrets` is the only package
/// that imports Security (§3.5, and the same rule that gave the WebKit importers
/// their own targets in ADR 011).
///
/// Keyed by the `Credential.id` that `ChordCore` holds, so the metadata half
/// (SQLite) and the secret half (Keychain) join on one value and neither
/// contains the other's data.
public protocol SecretStore: Sendable {
    /// Stores or replaces the password for a credential.
    func save(_ secret: String, for credentialID: UUID) throws
    /// Reads a password back, or nil when there is no item.
    func secret(for credentialID: UUID) throws -> String?
    /// Removes a credential's password. Succeeds when there was nothing there —
    /// deleting a credential must never fail because its secret already went.
    func delete(for credentialID: UUID) throws
    /// Every credential id that has a stored secret, for reconciling against the
    /// metadata table (an orphan on either side is a bug worth finding).
    func storedCredentialIDs() throws -> Set<UUID>
}

/// What can go wrong reaching the Keychain. Typed per §3.7 — no bare `NSError`.
public enum SecretStoreError: Error, Equatable {
    /// The Keychain refused the operation. Carries the raw `OSStatus` because it
    /// is the only thing that makes these diagnosable after the fact — `-34018`
    /// (missing entitlement) and `-25300` (not found) mean very different things.
    case keychain(status: Int32)
    /// A stored item was not valid UTF-8, i.e. something other than this wrote it.
    case corruptSecret
}
