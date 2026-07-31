import BrowserCore
import BrowserPersistence
import BrowserSecrets
import Foundation
import Testing

@testable import BrowserStore

/// The join between the two halves. V2's done-when is "no orphan row and no
/// orphan Keychain item", so most of this suite is about what survives a failure
/// part-way through, not about the happy path.
@Suite("Credential vault")
struct CredentialVaultTests {

    /// In-memory secrets: these tests are about the *coordination*, and a real
    /// Keychain is covered in `KeychainSecretStoreTests`.
    private final class FakeSecretStore: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var secrets: [UUID: String] = [:]
        /// Set to make the next save fail, standing in for a Keychain refusal.
        var failNextSave = false

        func save(_ secret: String, for credentialID: UUID) throws {
            if failNextSave {
                failNextSave = false
                throw SecretStoreError.keychain(status: -34018)
            }
            lock.withLock { secrets[credentialID] = secret }
        }
        func secret(for credentialID: UUID) throws -> String? {
            lock.withLock { secrets[credentialID] }
        }
        func delete(for credentialID: UUID) throws {
            _ = lock.withLock { secrets.removeValue(forKey: credentialID) }
        }
        func storedCredentialIDs() throws -> Set<UUID> {
            lock.withLock { Set(secrets.keys) }
        }
        /// Plants a secret with no metadata row — the orphan `reconcile` hunts.
        func plantOrphan(_ id: UUID) { lock.withLock { secrets[id] = "orphaned" } }
    }

    private func makeVault() throws -> (CredentialVault, FakeSecretStore) {
        let secrets = FakeSecretStore()
        let vault = CredentialVault(
            repository: SQLiteCredentialRepository(database: try BrowserDatabase.inMemory()),
            secrets: secrets
        )
        return (vault, secrets)
    }

    /// Recording a use writes `lastUsedSpaceId`, which has a foreign key to
    /// `space`, so that test needs a Space that exists.
    private func makeVaultWithSpace() async throws -> (CredentialVault, FakeSecretStore, Space) {
        let database = try BrowserDatabase.inMemory()
        let space = Space(name: "Work", sortIndex: 0)
        try await SQLiteTabRepository(database: database).saveSpaces([space])
        let secrets = FakeSecretStore()
        return (
            CredentialVault(
                repository: SQLiteCredentialRepository(database: database), secrets: secrets
            ),
            secrets,
            space
        )
    }

    @Test("A saved login round-trips through both halves")
    func roundTrip() async throws {
        let (vault, _) = try makeVault()
        let stored = try await vault.save(
            origin: "https://example.com", username: "me@example.com", secret: "hunter2"
        )

        #expect(try await vault.credentials(forOrigin: "https://example.com").count == 1)
        #expect(try await vault.secret(for: stored.id) == "hunter2")
    }

    @Test("Re-saving updates the password without duplicating the credential")
    func resaveUpdates() async throws {
        let (vault, _) = try makeVault()
        try await vault.save(
            origin: "https://example.com", username: "me@example.com", secret: "old"
        )
        let stored = try await vault.save(
            origin: "https://example.com", username: "me@example.com", secret: "new"
        )

        #expect(try await vault.all().count == 1)
        #expect(try await vault.secret(for: stored.id) == "new")
    }

    @Test("Reading a secret records the use, so the picker learns")
    func readingMarksUse() async throws {
        let (vault, _, space) = try await makeVaultWithSpace()
        let stored = try await vault.save(
            origin: "https://example.com", username: "me@example.com", secret: "hunter2"
        )

        _ = try await vault.secret(for: stored.id, usedIn: space.id)

        let reloaded = try await vault.all().first
        #expect(reloaded?.lastUsedSpaceID == space.id)
        #expect(reloaded?.lastUsedAt != nil)
    }

    @Test("Deleting removes both halves")
    func deleteRemovesBoth() async throws {
        let (vault, secrets) = try makeVault()
        let stored = try await vault.save(
            origin: "https://example.com", username: "me@example.com", secret: "hunter2"
        )

        try await vault.delete(id: stored.id)

        #expect(try await vault.all().isEmpty)
        #expect(try secrets.storedCredentialIDs().isEmpty, "no orphan secret is left behind")
    }

    @Test("A failed secret write leaves no credential behind")
    func failedSaveRollsBack() async throws {
        let (vault, secrets) = try makeVault()
        secrets.failNextSave = true

        await #expect(throws: (any Error).self) {
            try await vault.save(
                origin: "https://example.com", username: "me@example.com", secret: "hunter2"
            )
        }
        // A credential the user can see but that can never fill would be worse
        // than nothing.
        #expect(try await vault.all().isEmpty)
    }

    @Test("A failed re-save keeps the credential the user already had")
    func failedResaveKeepsExisting() async throws {
        let (vault, secrets) = try makeVault()
        let first = try await vault.save(
            origin: "https://example.com", username: "me@example.com", secret: "old"
        )
        secrets.failNextSave = true

        await #expect(throws: (any Error).self) {
            try await vault.save(
                origin: "https://example.com", username: "me@example.com", secret: "new"
            )
        }
        // Rolling back an update would delete a working credential because a
        // re-save failed — the one rollback that must not happen.
        #expect(try await vault.all().count == 1)
        #expect(try await vault.secret(for: first.id) == "old")
    }

    @Test("Reconcile removes a secret with no credential")
    func reconcileDropsOrphanSecrets() async throws {
        let (vault, secrets) = try makeVault()
        try await vault.save(
            origin: "https://example.com", username: "me@example.com", secret: "kept"
        )
        let orphan = UUID()
        secrets.plantOrphan(orphan)

        let removed = try await vault.reconcile()

        #expect(removed == 1)
        #expect(try secrets.secret(for: orphan) == nil, "unreachable password is gone")
        #expect(try await vault.all().count == 1, "the real credential is untouched")
    }

    @Test("Reconcile leaves a credential whose secret is missing")
    func reconcileKeepsSecretlessCredential() async throws {
        let (vault, secrets) = try makeVault()
        let stored = try await vault.save(
            origin: "https://example.com", username: "me@example.com", secret: "hunter2"
        )
        try secrets.delete(for: stored.id)

        #expect(try await vault.reconcile() == 0)
        // Which account you had on a site is worth keeping even when the
        // password is not recoverable.
        #expect(try await vault.all().count == 1)
    }

    @Test("A clean vault reconciles to nothing")
    func reconcileCleanIsNoop() async throws {
        let (vault, _) = try makeVault()
        try await vault.save(
            origin: "https://example.com", username: "me@example.com", secret: "hunter2"
        )
        #expect(try await vault.reconcile() == 0)
    }
}
