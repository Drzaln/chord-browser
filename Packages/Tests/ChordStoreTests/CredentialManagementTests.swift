import ChordCore
import ChordPersistence
import ChordSecrets
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

/// V6: the multi-step username carry-over, and reveal behind authentication.
@Suite("Credential management")
@MainActor
struct CredentialManagementTests {

    private final class MemorySecrets: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var secrets: [UUID: String] = [:]
        func save(_ secret: String, for id: UUID) throws { lock.withLock { secrets[id] = secret } }
        func secret(for id: UUID) throws -> String? { lock.withLock { secrets[id] } }
        func delete(for id: UUID) throws { _ = lock.withLock { secrets.removeValue(forKey: id) } }
        func storedCredentialIDs() throws -> Set<UUID> { lock.withLock { Set(secrets.keys) } }
    }

    /// Answers however the test tells it to, so no finger is required.
    private struct StubAuthenticator: VaultAuthenticator {
        let allow: Bool
        var isAvailable: Bool { true }
        func authenticate(reason: String) async throws(VaultUnlockFailure) {
            if !allow { throw .cancelled }
        }
    }

    private func makeStore(authenticator: (any VaultAuthenticator)? = nil) throws -> (
        TabStore, CredentialVault
    ) {
        let store = TabStore(
            engine: FakeWebEngine(), repository: FakeTabRepository(stored: []), clock: FixedClock()
        )
        let vault = CredentialVault(
            repository: SQLiteCredentialRepository(database: try ChordDatabase.inMemory()),
            secrets: MemorySecrets()
        )
        store.vault = vault
        store.authenticator = authenticator
        return (store, vault)
    }

    // MARK: - Multi-step logins

    @Test("A username submitted on one page pairs with a password submitted on the next")
    func carriesUsernameAcrossSteps() async throws {
        let (store, vault) = try makeStore()
        let origin = "https://accounts.google.com"

        // Step one: Google's email page submits a username and no password.
        await store.handleSubmittedLogin(
            origin: origin, username: "me@gmail.com", password: "", paneID: UUID()
        )
        #expect(store.pendingCredentialSave == nil, "a username alone is nothing to save yet")

        // Step two: the password page submits a password and no username.
        await store.handleSubmittedLogin(
            origin: origin, username: "", password: "hunter2", paneID: UUID()
        )

        let prompt = try #require(store.pendingCredentialSave)
        // Without the carry-over this saved a credential with a blank username,
        // which is what V5 did on the single most important site in the corpus.
        #expect(prompt.username == "me@gmail.com")

        await store.resolveCredentialSave(.save)
        #expect(try await vault.all().first?.username == "me@gmail.com")
    }

    @Test("A remembered username never crosses to a different site")
    func carryOverIsPerOrigin() async throws {
        let (store, _) = try makeStore()
        await store.handleSubmittedLogin(
            origin: "https://accounts.google.com", username: "me@gmail.com", password: "",
            paneID: UUID()
        )
        await store.handleSubmittedLogin(
            origin: "https://evil.example.com", username: "", password: "hunter2", paneID: UUID()
        )
        let prompt = try #require(store.pendingCredentialSave)
        #expect(prompt.username.isEmpty, "one site's username must not leak into another's save")
    }

    @Test("A submitted username still wins over the remembered one")
    func explicitUsernameWins() async throws {
        let (store, _) = try makeStore()
        let origin = "https://example.com"
        await store.handleSubmittedLogin(
            origin: origin, username: "first@example.com", password: "", paneID: UUID()
        )
        await store.handleSubmittedLogin(
            origin: origin, username: "second@example.com", password: "pw", paneID: UUID()
        )
        #expect(store.pendingCredentialSave?.username == "second@example.com")
    }

    // MARK: - Reveal

    @Test("Revealing a password requires authentication")
    func revealNeedsAuth() async throws {
        let (store, vault) = try makeStore(authenticator: StubAuthenticator(allow: true))
        let saved = try await vault.save(
            origin: "https://example.com", username: "me", secret: "hunter2"
        )
        #expect(await store.revealCredential(saved.id) == "hunter2")
    }

    @Test("A refused authentication reveals nothing")
    func refusedAuthRevealsNothing() async throws {
        let (store, vault) = try makeStore(authenticator: StubAuthenticator(allow: false))
        let saved = try await vault.save(
            origin: "https://example.com", username: "me", secret: "hunter2"
        )
        #expect(await store.revealCredential(saved.id) == nil)
    }

    @Test("With no authenticator, reveal is simply unavailable")
    func noAuthenticatorMeansNoReveal() async throws {
        let (store, vault) = try makeStore(authenticator: nil)
        let saved = try await vault.save(
            origin: "https://example.com", username: "me", secret: "hunter2"
        )
        // Missing should fail closed, not open.
        #expect(await store.revealCredential(saved.id) == nil)
    }

    @Test("Revealing does not count as using the password")
    func revealDoesNotRecordUse() async throws {
        let (store, vault) = try makeStore(authenticator: StubAuthenticator(allow: true))
        let saved = try await vault.save(
            origin: "https://example.com", username: "me", secret: "hunter2"
        )
        _ = await store.revealCredential(saved.id)
        // Looking at a password is not signing in with it; counting it would
        // make the picker's "last used" ordering meaningless.
        #expect(try await vault.all().first?.lastUsedAt == nil)
    }

    // MARK: - Management

    @Test("Deleting removes both halves")
    func deleteRemovesEverything() async throws {
        let (store, vault) = try makeStore()
        let saved = try await vault.save(
            origin: "https://example.com", username: "me", secret: "hunter2"
        )
        await store.deleteCredential(saved.id)
        #expect(await store.allCredentials().isEmpty)
        #expect(try await vault.reconcile() == 0, "no orphan secret is left behind")
    }

    @Test("A silenced site can be un-silenced")
    func neverSaveCanBeCleared() async throws {
        let (store, _) = try makeStore()
        let origin = "https://example.com"
        await store.handleSubmittedLogin(
            origin: origin, username: "me", password: "pw", paneID: UUID()
        )
        await store.resolveCredentialSave(.never)
        #expect(await store.neverSaveOrigins() == [origin])

        await store.clearNeverSave(origin: origin)
        #expect(await store.neverSaveOrigins().isEmpty)

        // And it offers again afterwards.
        await store.handleSubmittedLogin(
            origin: origin, username: "me", password: "pw", paneID: UUID()
        )
        #expect(store.pendingCredentialSave != nil)
    }
}
