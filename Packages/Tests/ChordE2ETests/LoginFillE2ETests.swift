import ChordCore
import ChordEngine
import ChordPersistence
import ChordSecrets
import ChordStore
import ChordTestSupport
import Foundation
import Testing

/// Filling, against real WebKit (V4).
///
/// This is the phase that cannot be unit-tested at all: whether a value actually
/// *lands* depends on how the page observes it, and the interesting failure —
/// a framework ignoring the change — needs a real DOM with a real value tracker.
@Suite("E2E: login fill", .serialized)
@MainActor
struct LoginFillE2ETests {

    /// A plain form that reports what it holds through the title, the convention
    /// the rest of the e2e suite uses to observe a page without an eval seam.
    private static let plainForm = TestHTTPServer.Route.page(
        path: "/login",
        title: "Login",
        body: """
            <form id="f">
              <input id="u" name="username" type="text" autocomplete="username">
              <input id="p" name="password" type="password" autocomplete="current-password">
              <button type="submit">Sign in</button>
            </form>
            <script>
              var form = document.getElementById('f');
              form.addEventListener('submit', function (e) {
                e.preventDefault();
                var u = document.getElementById('u').value;
                var p = document.getElementById('p').value;
                // "Session established": the form carried both values into a
                // real submit. Reported through the title, which is how the e2e
                // suite observes a page without an eval seam on the engine.
                document.title = 'submitted:' + u + '/' + p;
              });
              // The page submits itself once both fields hold something, so the
              // test never needs to reach into the DOM.
              document.addEventListener('input', function () {
                if (document.getElementById('u').value && document.getElementById('p').value) {
                  form.requestSubmit();
                }
              });
            </script>
            """
    )

    /// **The React case.** This reproduces React's value tracker: an instance
    /// property override that caches the last value it saw. A fill that assigns
    /// `el.value` goes through the override, updates the cache, and the change
    /// is then swallowed — the field looks filled and the app submits nothing.
    /// Only a fill through the *prototype* setter leaves the cache stale and is
    /// therefore seen.
    private static let trackedForm = TestHTTPServer.Route.page(
        path: "/tracked",
        title: "Tracked",
        body: """
            <input id="u" name="username" type="text" autocomplete="username">
            <input id="p" name="password" type="password" autocomplete="current-password">
            <script>
              function track(node) {
                var descriptor = Object.getOwnPropertyDescriptor(
                  window.HTMLInputElement.prototype, 'value'
                );
                var cached = node.value;
                Object.defineProperty(node, 'value', {
                  configurable: true,
                  get: function () { return descriptor.get.call(this); },
                  set: function (v) { cached = v; descriptor.set.call(this, v); }
                });
                node.addEventListener('input', function () {
                  // What a framework does: ignore an event whose value it
                  // believes it already knows about.
                  if (descriptor.get.call(node) === cached) { return; }
                  cached = descriptor.get.call(node);
                  node.setAttribute('data-seen', cached);
                  document.title = 'seen:' + document.getElementById('u').getAttribute('data-seen')
                    + '/' + (document.getElementById('p').getAttribute('data-seen') || '');
                });
              }
              track(document.getElementById('u'));
              track(document.getElementById('p'));
            </script>
            """
    )

    /// Builds a vault over the harness's own database, with in-memory secrets so
    /// the test never touches the real Keychain.
    private final class MemorySecrets: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var secrets: [UUID: String] = [:]
        func save(_ secret: String, for id: UUID) throws { lock.withLock { secrets[id] = secret } }
        func secret(for id: UUID) throws -> String? { lock.withLock { secrets[id] } }
        func delete(for id: UUID) throws { _ = lock.withLock { secrets.removeValue(forKey: id) } }
        func storedCredentialIDs() throws -> Set<UUID> { lock.withLock { Set(secrets.keys) } }
    }

    /// Shares the harness's database connection: opening a second one over the
    /// same file contends for the WAL and fails with "database is locked".
    private func attachVault(to harness: E2EHarness) throws -> CredentialVault {
        let vault = CredentialVault(
            repository: SQLiteCredentialRepository(database: harness.database),
            secrets: MemorySecrets()
        )
        harness.store.vault = vault
        return vault
    }

    /// Loads a page, waits for its login report, and returns the pane.
    private func loadAndDetect(
        _ harness: E2EHarness, path: String
    ) async -> UUID? {
        guard await harness.openAndLoad(await harness.server.url(path)),
            let paneID = harness.store.selectedTab?.focusedPaneID
        else { return nil }
        let found = await harness.wait {
            harness.store.runtime(for: paneID).loginForm?.passwordFieldID != nil
        }
        return found ? paneID : nil
    }

    @Test("A saved credential fills, and the page sees both values on submit")
    func fillsAndSubmits() async throws {
        let harness = try await E2EHarness.make(routes: [Self.plainForm])
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()
        let vault = try attachVault(to: harness)

        let paneID = try #require(await loadAndDetect(harness, path: "/login"))
        let origin = try #require(
            CredentialOrigin.canonical(
                for: harness.store.runtime(for: paneID).currentURL!,
                policy: .allowingInsecureLoopback
            )
        )
        let credential = try await vault.save(
            origin: origin, username: "me@example.com", secret: "hunter2"
        )

        let outcome = await harness.store.fillCredential(
            credential.id, intoPane: paneID, inSpace: nil
        )
        #expect(outcome == .filled(username: true, password: true))

        // The page submits itself once both fields are non-empty, and reads the
        // values back out of the form to build the title — which is what proves
        // they are really in the form rather than merely painted into it.
        let submitted = await harness.wait {
            harness.store.selectedTab?.focusedPane.title == "submitted:me@example.com/hunter2"
        }
        #expect(submitted, "the page must receive both values on submit")
    }

    @Test("A framework with a value tracker sees the change")
    func defeatsTheValueTracker() async throws {
        let harness = try await E2EHarness.make(routes: [Self.trackedForm])
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()
        let vault = try attachVault(to: harness)

        let paneID = try #require(await loadAndDetect(harness, path: "/tracked"))
        let origin = try #require(
            CredentialOrigin.canonical(
                for: harness.store.runtime(for: paneID).currentURL!,
                policy: .allowingInsecureLoopback
            )
        )
        let credential = try await vault.save(
            origin: origin, username: "tracked@example.com", secret: "s3cret"
        )

        _ = await harness.store.fillCredential(credential.id, intoPane: paneID, inSpace: nil)

        // The page only updates its title from *inside* the tracker's own check,
        // so this passing means the framework genuinely saw the value change.
        let seen = await harness.wait {
            harness.store.selectedTab?.focusedPane.title == "seen:tracked@example.com/s3cret"
        }
        #expect(seen, "a direct value assignment would be swallowed by the tracker")
    }

    @Test("A credential for another origin is refused")
    func refusesForeignOrigin() async throws {
        let harness = try await E2EHarness.make(routes: [Self.plainForm])
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()
        let vault = try attachVault(to: harness)

        let paneID = try #require(await loadAndDetect(harness, path: "/login"))
        // Saved for a site the pane is *not* showing.
        let credential = try await vault.save(
            origin: "https://evil.example.com", username: "victim", secret: "hunter2"
        )

        let outcome = await harness.store.fillCredential(
            credential.id, intoPane: paneID, inSpace: nil
        )
        #expect(outcome == .originMismatch)

        // And nothing reached the page: the self-submitting form never fires,
        // because neither field was ever given a value.
        let leaked = await harness.wait(timeout: .seconds(2)) {
            harness.store.selectedTab?.focusedPane.title.contains("hunter2") == true
        }
        #expect(leaked == false, "a refused fill must put nothing in the page")
    }

    @Test("Filling records the use, so the picker learns")
    func fillRecordsUse() async throws {
        let harness = try await E2EHarness.make(routes: [Self.plainForm])
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()
        let vault = try attachVault(to: harness)

        let paneID = try #require(await loadAndDetect(harness, path: "/login"))
        let origin = try #require(
            CredentialOrigin.canonical(
                for: harness.store.runtime(for: paneID).currentURL!,
                policy: .allowingInsecureLoopback
            )
        )
        let credential = try await vault.save(
            origin: origin, username: "me@example.com", secret: "hunter2"
        )

        _ = await harness.store.fillCredential(credential.id, intoPane: paneID, inSpace: nil)

        let reloaded = try await vault.all().first
        #expect(reloaded?.lastUsedAt != nil)
    }
}
