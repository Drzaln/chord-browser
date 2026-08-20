import Foundation
import Testing

@testable import ChordSecrets

/// Round-trips against the **real** Keychain, like `DataStoreIsolationTests` does
/// against real data stores: a fake proving a round trip would prove nothing
/// about the thing the vault depends on.
///
/// Two deliberate constraints. Every run uses a **unique service name**, so these
/// never touch the real vault and two runs cannot see each other's items — which
/// also sidesteps the unsandboxed test binary's unstable code identity. And each
/// test cleans up after itself, because a leaked item is a password-shaped thing
/// left in the developer's login keychain.
///
/// What these cannot prove: anything about App Sandbox or Hardened Runtime.
/// `swift test` runs unsandboxed (§7.6). The sandboxed behaviour was measured by
/// hand against a Release build — see `KeychainSecretStore`'s own note.
@Suite("Keychain secret store")
struct KeychainSecretStoreTests {

    /// A store no other test run shares.
    private func makeStore() -> KeychainSecretStore {
        KeychainSecretStore(service: "com.rizal.chord.vault.tests.\(UUID().uuidString)")
    }

    @Test("A secret round-trips")
    func roundTrip() throws {
        let store = makeStore()
        let id = UUID()
        defer { try? store.delete(for: id) }

        try store.save("correct horse battery staple", for: id)
        #expect(try store.secret(for: id) == "correct horse battery staple")
    }

    @Test("An unknown credential reads back nil rather than throwing")
    func missingIsNil() throws {
        let store = makeStore()
        #expect(try store.secret(for: UUID()) == nil)
    }

    @Test("Saving twice replaces rather than duplicating")
    func saveReplaces() throws {
        let store = makeStore()
        let id = UUID()
        defer { try? store.delete(for: id) }

        try store.save("first", for: id)
        try store.save("second", for: id)
        #expect(try store.secret(for: id) == "second")
        #expect(try store.storedCredentialIDs() == [id])
    }

    @Test("Deleting removes the secret, and deleting again is not an error")
    func deleteIsIdempotent() throws {
        let store = makeStore()
        let id = UUID()
        try store.save("gone shortly", for: id)
        try store.delete(for: id)
        #expect(try store.secret(for: id) == nil)
        // A credential whose secret already went must still be deletable.
        try store.delete(for: id)
    }

    @Test("Two credentials do not see each other's secrets")
    func credentialsAreIsolated() throws {
        let store = makeStore()
        let work = UUID()
        let personal = UUID()
        defer {
            try? store.delete(for: work)
            try? store.delete(for: personal)
        }

        try store.save("work-secret", for: work)
        try store.save("personal-secret", for: personal)
        #expect(try store.secret(for: work) == "work-secret")
        #expect(try store.secret(for: personal) == "personal-secret")
        #expect(try store.storedCredentialIDs() == [work, personal])
    }

    @Test("Two stores with different services are separate vaults")
    func storesAreNamespaced() throws {
        let first = makeStore()
        let second = makeStore()
        let id = UUID()
        defer {
            try? first.delete(for: id)
            try? second.delete(for: id)
        }

        try first.save("only in the first", for: id)
        #expect(try second.secret(for: id) == nil)
    }

    @Test("A password with non-ASCII characters survives intact")
    func unicodeSurvives() throws {
        let store = makeStore()
        let id = UUID()
        defer { try? store.delete(for: id) }

        let secret = "pässwörd–🔐–日本語"
        try store.save(secret, for: id)
        #expect(try store.secret(for: id) == secret)
    }

    @Test("An empty vault lists nothing")
    func emptyVaultListsNothing() throws {
        #expect(try makeStore().storedCredentialIDs().isEmpty)
    }
}
