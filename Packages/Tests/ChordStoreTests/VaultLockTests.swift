import ChordCore
import ChordPersistence
import ChordSecrets
import ChordTestSupport
import Foundation
import Testing

@testable import ChordStore

/// V7: the lock. Idle, sleep, and screen lock all lock the vault; a refused
/// unlock fills nothing; a machine with no gate at all is not left with a vault
/// it can never open.
@Suite("Vault lock")
@MainActor
struct VaultLockTests {

    private final class MemorySecrets: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var secrets: [UUID: String] = [:]
        func save(_ secret: String, for id: UUID) throws { lock.withLock { secrets[id] = secret } }
        func secret(for id: UUID) throws -> String? { lock.withLock { secrets[id] } }
        func delete(for id: UUID) throws { _ = lock.withLock { secrets.removeValue(forKey: id) } }
        func storedCredentialIDs() throws -> Set<UUID> { lock.withLock { Set(secrets.keys) } }
    }

    /// `FixedClock` is a value type and `TabStore` holds its clock for life, so
    /// an idle test needs one whose `now` can be moved after the store is built.
    private final class TickingClock: Clock, @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { value = start }
        var now: Date { lock.withLock { value } }
        func advance(_ interval: TimeInterval) { lock.withLock { value += interval } }
    }

    /// Counts prompts, so "did it ask again?" is answerable.
    private final class CountingAuthenticator: VaultAuthenticator, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let allow: Bool
        let available: Bool

        init(allow: Bool = true, available: Bool = true) {
            self.allow = allow
            self.available = available
        }

        var isAvailable: Bool { available }
        var prompts: Int { lock.withLock { count } }

        func authenticate(reason: String) async throws(VaultUnlockFailure) {
            lock.withLock { count += 1 }
            guard available else { throw .unavailable }
            guard allow else { throw .cancelled }
        }
    }

    private struct Fixture {
        let store: TabStore
        let engine: FakeWebEngine
        let vault: CredentialVault
        let clock: TickingClock
        let authenticator: CountingAuthenticator
        let credentialID: UUID
        let paneID: UUID
    }

    private func makeFixture(
        allow: Bool = true, available: Bool = true, timeout: VaultLockTimeout = .default
    ) async throws -> Fixture {
        let clock = TickingClock()
        let engine = FakeWebEngine()
        let store = TabStore(
            engine: engine, repository: FakeTabRepository(stored: []), clock: clock
        )
        let vault = CredentialVault(
            repository: SQLiteCredentialRepository(database: try ChordDatabase.inMemory()),
            secrets: MemorySecrets()
        )
        let authenticator = CountingAuthenticator(allow: allow, available: available)
        store.vault = vault
        store.authenticator = authenticator
        // Never the real `~/Library/Preferences` — the timeout is persisted on
        // assignment, and a test has no business writing the developer's profile.
        store.preferenceStore = InMemoryPreferenceStore()
        store.vaultLockTimeout = timeout

        let origin = "https://example.com"
        let credential = try await vault.save(origin: origin, username: "me", secret: "hunter2")

        let paneID = UUID()
        store.runtime(for: paneID).currentURL = URL(string: origin + "/login")
        // Through the classifier rather than by hand: its memberwise init is
        // internal, and a fixture built from descriptors is the shape the page
        // actually reports anyway.
        store.runtime(for: paneID).loginForm = LoginFormClassifier.analyse([
            LoginFieldDescriptor(elementID: "u", type: "text", autocomplete: "username"),
            LoginFieldDescriptor(
                elementID: "p", type: "password", autocomplete: "current-password", index: 1
            ),
        ])

        return Fixture(
            store: store, engine: engine, vault: vault, clock: clock,
            authenticator: authenticator, credentialID: credential.id, paneID: paneID
        )
    }

    // MARK: - The gate

    @Test("The vault starts locked, and a fill unlocks it first")
    func fillUnlocksFirst() async throws {
        let f = try await makeFixture()
        #expect(f.store.isVaultLocked, "a launched browser has an unlocked vault only if asked")

        let result = await f.store.fillCredential(f.credentialID, intoPane: f.paneID, inSpace: nil)
        #expect(result == .filled(username: true, password: true))
        #expect(f.authenticator.prompts == 1)
        #expect(f.store.isVaultLocked == false)
    }

    @Test("A cancelled authentication fills nothing and says so")
    func refusedAuthFillsNothing() async throws {
        let f = try await makeFixture(allow: false)

        let result = await f.store.fillCredential(f.credentialID, intoPane: f.paneID, inSpace: nil)
        #expect(result == .vaultLocked, "the UI has to be able to say why nothing happened")
        // The decisive assertion: the engine was never asked, so no password went
        // anywhere near the page.
        #expect(f.engine.fills.isEmpty)
        #expect(f.store.isVaultLocked)
    }

    @Test("A second fill inside the idle window does not prompt again")
    func unlockedVaultDoesNotRePrompt() async throws {
        let f = try await makeFixture()
        _ = await f.store.fillCredential(f.credentialID, intoPane: f.paneID, inSpace: nil)
        f.clock.advance(60)
        _ = await f.store.fillCredential(f.credentialID, intoPane: f.paneID, inSpace: nil)

        #expect(f.authenticator.prompts == 1, "re-authenticating per fill is what gets it turned off")
        #expect(f.engine.fills.count == 2)
    }

    // MARK: - Idle

    @Test("Idling past the timeout locks the vault, and the next fill prompts again")
    func idleLocks() async throws {
        let f = try await makeFixture(timeout: .after(15 * 60))
        _ = await f.store.fillCredential(f.credentialID, intoPane: f.paneID, inSpace: nil)
        #expect(f.store.isVaultLocked == false)

        f.clock.advance(15 * 60)
        f.store.refreshVaultLock()
        #expect(f.store.isVaultLocked)

        _ = await f.store.fillCredential(f.credentialID, intoPane: f.paneID, inSpace: nil)
        #expect(f.authenticator.prompts == 2)
    }

    @Test("Using the vault restarts the idle clock")
    func useRestartsTheClock() async throws {
        let f = try await makeFixture(timeout: .after(15 * 60))
        _ = await f.store.fillCredential(f.credentialID, intoPane: f.paneID, inSpace: nil)

        // Two fills ten minutes apart: without the restart the second one lands
        // past the window and re-prompts mid-sitting.
        f.clock.advance(10 * 60)
        _ = await f.store.fillCredential(f.credentialID, intoPane: f.paneID, inSpace: nil)
        f.clock.advance(10 * 60)
        f.store.refreshVaultLock()

        #expect(f.store.isVaultLocked == false)
        #expect(f.authenticator.prompts == 1)
    }

    @Test("The 'only on sleep or screen lock' setting turns the idle clock off")
    func neverTimeoutDoesNotIdleLock() async throws {
        let f = try await makeFixture(timeout: .never)
        _ = await f.store.fillCredential(f.credentialID, intoPane: f.paneID, inSpace: nil)

        f.clock.advance(24 * 60 * 60)
        f.store.refreshVaultLock()
        #expect(f.store.isVaultLocked == false)

        // It is not "never lock", and the label says so: the event locks still fire.
        f.store.lockVault()
        #expect(f.store.isVaultLocked)
    }

    // MARK: - Event locks (sleep, screen lock, Lock Now)

    @Test("Locking the vault takes effect immediately and re-prompts on the next fill")
    func lockNowLocks() async throws {
        let f = try await makeFixture()
        _ = await f.store.fillCredential(f.credentialID, intoPane: f.paneID, inSpace: nil)

        // What the app layer calls on sleep, screen lock, and fast user switching,
        // and what Lock Now calls in Settings.
        f.store.lockVault()
        #expect(f.store.isVaultLocked)

        _ = await f.store.fillCredential(f.credentialID, intoPane: f.paneID, inSpace: nil)
        #expect(f.authenticator.prompts == 2)
    }

    // MARK: - No gate available

    @Test("With no biometry and no passcode, filling still works")
    func unavailableGateDoesNotDisableFilling() async throws {
        let f = try await makeFixture(available: false)
        let result = await f.store.fillCredential(f.credentialID, intoPane: f.paneID, inSpace: nil)
        // A lock nothing can open is not security, it is a vault the owner cannot
        // use — and the attacker it would stop already has the machine.
        #expect(result == .filled(username: true, password: true))
    }

    @Test("Revealing still refuses when there is no gate")
    func unavailableGateStillBlocksReveal() async throws {
        let f = try await makeFixture(available: false)
        // Reveal is the one place a password is put on screen as text, so it fails
        // closed where filling fails open.
        #expect(await f.store.revealCredential(f.credentialID) == nil)
    }

    @Test("A successful reveal counts as an unlock")
    func revealUnlocks() async throws {
        let f = try await makeFixture()
        #expect(await f.store.revealCredential(f.credentialID) == "hunter2")
        #expect(f.store.isVaultLocked == false)
        // ...so the fill that follows it does not ask a second time.
        _ = await f.store.fillCredential(f.credentialID, intoPane: f.paneID, inSpace: nil)
        #expect(f.authenticator.prompts == 1)
    }

    // MARK: - The fill affordance after a vault change

    @Test("Saving a password offers it on the page already open")
    func savingRefreshesTheOpenPage() async throws {
        let f = try await makeFixture()
        // A different origin, so the fixture's own credential is not the answer.
        let paneID = UUID()
        let origin = "https://saved-just-now.example"
        f.store.runtime(for: paneID).currentURL = URL(string: origin + "/login")
        f.store.runtime(for: paneID).loginForm = f.store.runtime(for: f.paneID).loginForm
        #expect(f.store.runtime(for: paneID).fillableCredentials.isEmpty)

        await f.store.handleSubmittedLogin(
            origin: origin, username: "me", password: "hunter2", paneID: paneID
        )
        await f.store.resolveCredentialSave(.save)
        try await Task.sleep(for: .milliseconds(200))

        // Found live: without this the key stayed hidden until the tab navigated
        // again, which reads as the save having failed.
        #expect(f.store.runtime(for: paneID).fillableCredentials.count == 1)

        await f.store.deleteCredential(
            try #require(f.store.runtime(for: paneID).fillableCredentials.first).id
        )
        try await Task.sleep(for: .milliseconds(200))
        #expect(f.store.runtime(for: paneID).fillableCredentials.isEmpty)
    }

    // MARK: - The preference

    @Test("The timeout preference round-trips without touching UserDefaults")
    func timeoutPersists() async throws {
        let defaults = InMemoryPreferenceStore()
        let f = try await makeFixture()
        f.store.preferenceStore = defaults
        f.store.vaultLockTimeout = .after(60)

        #expect(Preferences.loadVaultLockTimeout(defaults) == .after(60))
        #expect(VaultLockTimeout.presets.contains(.default))
    }
}
