import BrowserCore
import BrowserPersistence
import BrowserSecrets
import BrowserStore
import BrowserTestSupport
import Foundation
import Testing

/// Capture and the save bar (V5), against real WebKit.
///
/// V5's done-when, literally: signing in on the test page offers to save, and a
/// relaunch offers the credential back.
@Suite("E2E: login capture", .serialized)
@MainActor
struct LoginCaptureE2ETests {

    /// Types into its own fields and submits, which is the closest a test can get
    /// to a user signing in — the values travel the same path either way.
    private static func signInPage(username: String, password: String) -> TestHTTPServer.Route {
        .page(
            path: "/signin",
            title: "Sign in",
            body: """
                <form id="f">
                  <input id="u" name="username" type="text" autocomplete="username">
                  <input id="p" name="password" type="password" autocomplete="current-password">
                  <button type="submit">Sign in</button>
                </form>
                <script>
                  document.getElementById('f').addEventListener('submit', function (e) {
                    e.preventDefault();
                    document.title = 'signed-in';
                  });
                  setTimeout(function () {
                    document.getElementById('u').value = '\(username)';
                    document.getElementById('p').value = '\(password)';
                    document.getElementById('f').requestSubmit();
                  }, 300);
                </script>
                """
        )
    }

    /// In-memory secrets so no test touches the real Keychain.
    private final class MemorySecrets: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var secrets: [UUID: String] = [:]
        func save(_ secret: String, for id: UUID) throws { lock.withLock { secrets[id] = secret } }
        func secret(for id: UUID) throws -> String? { lock.withLock { secrets[id] } }
        func delete(for id: UUID) throws { _ = lock.withLock { secrets.removeValue(forKey: id) } }
        func storedCredentialIDs() throws -> Set<UUID> { lock.withLock { Set(secrets.keys) } }
    }

    /// One secret store shared across a relaunch, standing in for the Keychain,
    /// which of course survives one.
    private static let sharedSecrets = MemorySecrets()

    @discardableResult
    private func attachVault(
        to store: TabStore, database: BrowserDatabase, secrets: any SecretStore
    ) -> CredentialVault {
        let vault = CredentialVault(
            repository: SQLiteCredentialRepository(database: database), secrets: secrets
        )
        store.vault = vault
        store.loginOriginPolicy = .allowingInsecureLoopback
        return vault
    }

    @Test("Signing in offers to save, and a relaunch offers the credential back")
    func capturesAndSurvivesRelaunch() async throws {
        let harness = try await E2EHarness.make(
            routes: [Self.signInPage(username: "me@example.com", password: "hunter2")]
        )
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()
        let secrets = MemorySecrets()
        attachVault(to: harness.store, database: harness.database, secrets: secrets)

        #expect(await harness.openAndLoad(await harness.server.url("/signin")))

        // The page signs itself in 300ms after load.
        let offered = await harness.wait { harness.store.pendingCredentialSave != nil }
        #expect(offered, "submitting a login must offer to save it")
        let prompt = try #require(harness.store.pendingCredentialSave)
        #expect(prompt.username == "me@example.com")
        #expect(prompt.isUpdate == false, "a first save is not an update")

        await harness.store.resolveCredentialSave(.save)
        #expect(harness.store.pendingCredentialSave == nil)

        // Relaunch: a second store over the same database, as after a quit.
        let relaunched = try harness.relaunch()
        await relaunched.restore()
        attachVault(to: relaunched, database: harness.database, secrets: secrets)

        let origin = try #require(
            CredentialOrigin.canonical(
                for: await harness.server.url("/signin"), policy: .allowingInsecureLoopback
            )
        )
        let offeredBack = try await #require(relaunched.vault).credentials(forOrigin: origin)
        #expect(offeredBack.count == 1)
        #expect(offeredBack.first?.username == "me@example.com")
        // And the password itself came back, not just the metadata.
        let id = try #require(offeredBack.first?.id)
        #expect(try await #require(relaunched.vault).secret(for: id) == "hunter2")
    }

    @Test("Signing in again with the same password does not ask twice")
    func doesNotReofferAnUnchangedPassword() async throws {
        let harness = try await E2EHarness.make(
            routes: [Self.signInPage(username: "me@example.com", password: "hunter2")]
        )
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()
        let vault = attachVault(
            to: harness.store, database: harness.database, secrets: MemorySecrets()
        )

        let origin = try #require(
            CredentialOrigin.canonical(
                for: await harness.server.url("/signin"), policy: .allowingInsecureLoopback
            )
        )
        // Already saved, with the very password the page is about to submit.
        try await vault.save(origin: origin, username: "me@example.com", secret: "hunter2")

        #expect(await harness.openAndLoad(await harness.server.url("/signin")))
        _ = await harness.wait(timeout: .seconds(3)) {
            harness.store.pendingCredentialSave != nil
        }
        // Asking every single time you sign in to a site you already saved is
        // the behaviour that makes people turn a password manager off.
        #expect(harness.store.pendingCredentialSave == nil)
    }

    @Test("A changed password offers an update rather than a second entry")
    func offersUpdateForChangedPassword() async throws {
        let harness = try await E2EHarness.make(
            routes: [Self.signInPage(username: "me@example.com", password: "new-password")]
        )
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()
        let vault = attachVault(
            to: harness.store, database: harness.database, secrets: MemorySecrets()
        )

        let origin = try #require(
            CredentialOrigin.canonical(
                for: await harness.server.url("/signin"), policy: .allowingInsecureLoopback
            )
        )
        try await vault.save(origin: origin, username: "me@example.com", secret: "old-password")

        #expect(await harness.openAndLoad(await harness.server.url("/signin")))
        #expect(await harness.wait { harness.store.pendingCredentialSave != nil })
        let prompt = try #require(harness.store.pendingCredentialSave)
        #expect(prompt.isUpdate, "the bar must say Update, not Save")

        await harness.store.resolveCredentialSave(.save)
        let stored = try await vault.credentials(forOrigin: origin)
        #expect(stored.count == 1, "an update must not create a second credential")
        #expect(try await vault.secret(for: #require(stored.first?.id)) == "new-password")
    }

    @Test("Never means never: the site stops offering, and nothing is saved")
    func neverSilencesTheSite() async throws {
        let harness = try await E2EHarness.make(
            routes: [Self.signInPage(username: "me@example.com", password: "hunter2")]
        )
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()
        let vault = attachVault(
            to: harness.store, database: harness.database, secrets: MemorySecrets()
        )

        #expect(await harness.openAndLoad(await harness.server.url("/signin")))
        #expect(await harness.wait { harness.store.pendingCredentialSave != nil })
        await harness.store.resolveCredentialSave(.never)

        #expect(try await vault.all().isEmpty, "declining must save nothing")

        // Sign in again: the site is silenced now.
        #expect(await harness.openAndLoad(await harness.server.url("/signin")))
        _ = await harness.wait(timeout: .seconds(3)) {
            harness.store.pendingCredentialSave != nil
        }
        #expect(harness.store.pendingCredentialSave == nil)
    }

    @Test("Declining once saves nothing but leaves the site free to ask again")
    func dismissIsNotNever() async throws {
        let harness = try await E2EHarness.make(
            routes: [Self.signInPage(username: "me@example.com", password: "hunter2")]
        )
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()
        let vault = attachVault(
            to: harness.store, database: harness.database, secrets: MemorySecrets()
        )

        #expect(await harness.openAndLoad(await harness.server.url("/signin")))
        #expect(await harness.wait { harness.store.pendingCredentialSave != nil })
        await harness.store.resolveCredentialSave(.dismiss)
        #expect(try await vault.all().isEmpty)

        #expect(await harness.openAndLoad(await harness.server.url("/signin")))
        #expect(
            await harness.wait { harness.store.pendingCredentialSave != nil },
            "a one-time dismissal must not silence the site"
        )
    }
}
