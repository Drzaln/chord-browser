import ChordCore
import ChordStore
import ChordTestSupport
import Foundation
import Testing

/// The page-side half of V3, against real WebKit and real HTTP.
///
/// Unit tests prove the *classifier*; only this can prove the collector — that a
/// script injected at document start into a real page finds the right elements,
/// survives the DOM changing under it, and gets its report back across the
/// message-handler seam. The shadow-DOM and mutation cases in particular have no
/// meaning without a browser.
@Suite("E2E: login form detection", .serialized)
@MainActor
struct LoginFormE2ETests {

    /// A plain server-rendered login, of the npm variety: no `autocomplete`
    /// anywhere, so only names and labels say what the fields are.
    private static let plainLogin = TestHTTPServer.Route.page(
        path: "/login",
        title: "Login",
        body: """
            <form>
              <label for="u">Username</label>
              <input id="u" name="username" type="text">
              <label for="p">Password</label>
              <input id="p" name="password" type="password">
              <button type="submit">Sign in</button>
            </form>
            """
    )

    /// Google's shape: a visible username step with an invisible decoy password
    /// field, and GitHub's: invisible honeypots. Both must be ignored.
    private static let decoyLogin = TestHTTPServer.Route.page(
        path: "/decoy",
        title: "Decoy",
        body: """
            <form>
              <input name="identifier" type="text" autocomplete="username">
              <input name="hiddenPassword" type="password" style="display:none">
              <input name="required_field_067" type="text"
                     style="position:absolute;width:0;height:0;overflow:hidden">
            </form>
            """
    )

    /// Reddit's shape: the login exists only inside a shadow root, so a
    /// collector that does not pierce shadow DOM reports nothing at all.
    private static let shadowLogin = TestHTTPServer.Route.page(
        path: "/shadow",
        title: "Shadow",
        body: """
            <div id="host"></div>
            <script>
              const root = document.getElementById('host').attachShadow({ mode: 'open' });
              root.innerHTML =
                '<input name="username" type="text" autocomplete="username webauthn">' +
                '<input name="password" type="password" autocomplete="current-password">';
            </script>
            """
    )

    /// A single-page app: the form does not exist when the document loads, and
    /// appears a moment later. Without a MutationObserver this is never seen.
    private static let lateLogin = TestHTTPServer.Route.page(
        path: "/late",
        title: "Late",
        body: """
            <div id="mount"></div>
            <script>
              setTimeout(() => {
                document.getElementById('mount').innerHTML =
                  '<input name="email" type="email" autocomplete="username">' +
                  '<input name="password" type="password" autocomplete="current-password">';
              }, 400);
            </script>
            """
    )

    /// Waits for the pane to report a login, then hands back what it said.
    private func analysis(
        _ harness: E2EHarness, path: String
    ) async -> LoginFormAnalysis? {
        guard await harness.openAndLoad(await harness.server.url(path)),
            let paneID = harness.store.selectedTab?.focusedPaneID
        else { return nil }
        await harness.wait { harness.store.runtime(for: paneID).loginForm != nil }
        return harness.store.runtime(for: paneID).loginForm
    }

    @Test("A plain login form is detected end to end")
    func detectsPlainLogin() async throws {
        let harness = try await E2EHarness.make(routes: [Self.plainLogin])
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()

        let result = try #require(await analysis(harness, path: "/login"))
        #expect(result.kind == .login)
        #expect(result.usernameFieldID != nil)
        #expect(result.passwordFieldID != nil)
    }

    @Test("Invisible decoys and honeypots are never reported as fillable")
    func ignoresDecoysAndHoneypots() async throws {
        let harness = try await E2EHarness.make(routes: [Self.decoyLogin])
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()

        let result = try #require(await analysis(harness, path: "/decoy"))
        // The username step is fillable; the hidden password field is not, and
        // the honeypot is not a username.
        #expect(result.kind == .login)
        #expect(result.usernameFieldID != nil)
        #expect(result.passwordFieldID == nil, "a display:none password must never be a target")
        #expect(result.isMultiStep)
    }

    @Test("A login inside shadow DOM is found")
    func piercesShadowDOM() async throws {
        let harness = try await E2EHarness.make(routes: [Self.shadowLogin])
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()

        // Reddit's real login is exactly this shape, and it is invisible to
        // `document.querySelectorAll('input')`.
        let result = try #require(await analysis(harness, path: "/shadow"))
        #expect(result.kind == .login)
        #expect(result.usernameFieldID != nil)
        #expect(result.passwordFieldID != nil)
    }

    @Test("A form that appears after load is still noticed")
    func noticesLateForm() async throws {
        let harness = try await E2EHarness.make(routes: [Self.lateLogin])
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()

        guard await harness.openAndLoad(await harness.server.url("/late")),
            let paneID = harness.store.selectedTab?.focusedPaneID
        else { Issue.record("page did not load"); return }

        // The form is injected 400ms after load, so the first report says
        // nothing and the observer has to catch the second.
        let found = await harness.wait {
            harness.store.runtime(for: paneID).loginForm?.passwordFieldID != nil
        }
        #expect(found, "the MutationObserver must catch a form rendered after load")
    }

    @Test("A page with no login reports that it has none")
    func reportsNoLogin() async throws {
        let harness = try await E2EHarness.make(
            routes: [.page(path: "/plain", title: "Plain", body: "<h1>No forms here</h1>")]
        )
        defer { Task { await harness.tearDown() } }
        await harness.store.restore()

        let result = try #require(await analysis(harness, path: "/plain"))
        // "Reported nothing fillable" is a different state from "not looked
        // yet", and the runtime has to be able to tell them apart.
        #expect(result.kind == .none)
    }
}
