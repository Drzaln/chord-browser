import BrowserCore
import BrowserSecrets
import Foundation

/// Joins the vault's two halves — metadata in SQLite, secret in the Keychain —
/// and is the only thing allowed to write either (V2 —
/// `docs/design/password-vault.md`).
///
/// It exists because the split that keeps passwords out of the database also
/// creates the one failure mode the split can suffer: a row with no secret, or a
/// secret with no row. Every mutation here writes both halves in an order chosen
/// so that an interruption leaves the recoverable state, and `reconcile()` cleans
/// up after the interruptions that still happen (a crash between two writes, a
/// database restored from a backup taken at a different moment than the
/// Keychain).
///
/// No UI and nothing wired into the app yet: V2 is storage.
public struct CredentialVault: Sendable {
    private let repository: any CredentialRepository
    private let secrets: any SecretStore

    public init(repository: any CredentialRepository, secrets: any SecretStore) {
        self.repository = repository
        self.secrets = secrets
    }

    /// Saves a login, or updates the password on one already saved for this
    /// `(origin, username)`.
    ///
    /// Order matters: metadata first, then the secret. The reverse would leave a
    /// secret under an id no row references — invisible to the user and
    /// unreachable except by `reconcile()`. This way an interruption leaves a
    /// visible credential whose secret is missing, which the UI can report and
    /// the user can fix by saving again.
    @discardableResult
    public func save(
        origin: String, username: String, secret: String, spaceID: UUID? = nil, now: Date = Date()
    ) async throws -> Credential {
        let stored = try await repository.upsert(
            Credential(
                origin: origin,
                username: username,
                createdAt: now,
                lastUsedAt: nil,
                lastUsedSpaceID: spaceID
            )
        )
        do {
            try secrets.save(secret, for: stored.id)
        } catch {
            // Roll the metadata back, but only for a credential this call
            // created. Rolling back an *update* would delete a credential the
            // user already had because a re-save failed.
            if stored.createdAt == now {
                try? await repository.delete(id: stored.id)
            }
            throw error
        }
        return stored
    }

    /// The credentials offerable on a page, best candidate first. Metadata only —
    /// reading a secret is a separate, deliberate step.
    public func credentials(forOrigin origin: String, spaceID: UUID? = nil) async throws
        -> [Credential]
    {
        try await repository.credentials(forOrigin: origin, spaceID: spaceID)
    }

    /// Reads one password, and records the use so the picker learns.
    ///
    /// Deliberately not part of `credentials(forOrigin:)`: listing what exists and
    /// handing over a secret are different acts, and only the second one should
    /// ever be behind the lock.
    public func secret(for id: UUID, usedIn spaceID: UUID? = nil, now: Date = Date()) async throws
        -> String?
    {
        guard let secret = try secrets.secret(for: id) else { return nil }
        try await repository.markUsed(id: id, at: now, inSpace: spaceID)
        return secret
    }

    /// Reads a secret **without** recording a use.
    ///
    /// Separate from `secret(for:usedIn:)` because capture compares the stored
    /// password against what was just typed, and that comparison is not a use —
    /// counting it would reorder the picker every time you sign in manually.
    public func storedSecret(for id: UUID) throws -> String? {
        try secrets.secret(for: id)
    }

    /// Whether saving is silenced for an origin (V5).
    func isNeverSave(origin: String) async throws -> Bool {
        try await repository.isNeverSave(origin: origin)
    }

    /// Silences saving for an origin (V5).
    func setNeverSave(origin: String) async throws {
        try await repository.setNeverSave(origin: origin)
    }

    /// Silenced origins, for the Settings list (V6).
    public func neverSaveOrigins() async throws -> [String] {
        try await repository.neverSaveOrigins()
    }

    /// Un-silences an origin (V6).
    public func clearNeverSave(origin: String) async throws {
        try await repository.clearNeverSave(origin: origin)
    }

    /// Every saved credential, for the Settings list.
    public func all() async throws -> [Credential] {
        try await repository.all()
    }

    /// Deletes both halves.
    ///
    /// The secret goes first here — the opposite of `save`, and for the same
    /// reason. If this is interrupted, what survives is a credential the user can
    /// still see and delete again, rather than a secret they can no longer see or
    /// remove through any UI.
    public func delete(id: UUID) async throws {
        try secrets.delete(for: id)
        try await repository.delete(id: id)
    }

    /// Drops secrets with no metadata row.
    ///
    /// The orphan direction that matters: an unreferenced Keychain item is a
    /// password the user cannot see in Settings and therefore cannot delete —
    /// exactly the thing a password manager must not accumulate. Returns how many
    /// were removed so a caller can report rather than silently tidy.
    ///
    /// The other direction (a row whose secret is gone) is left alone
    /// deliberately: it is visible, harmless, and deleting it would destroy the
    /// user's record of *which account they had on a site*, which is worth
    /// keeping even when the password itself is unrecoverable.
    @discardableResult
    public func reconcile() async throws -> Int {
        let known = try await repository.storedIDs()
        let orphans = try secrets.storedCredentialIDs().subtracting(known)
        for id in orphans {
            try secrets.delete(for: id)
        }
        return orphans.count
    }
}
