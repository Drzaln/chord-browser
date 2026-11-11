import Foundation
import Testing
import WebKit

@testable import ChordEngine

/// The agent's page script (MCP, 0mu.2) against real WebKit: refs, clicks,
/// typing through a React-style value tracker, the password refusal, forms.
@Suite("Agent page script", .serialized)
@MainActor
struct AgentPageScriptTests {
    private let world = WKContentWorld.world(name: "chord.agent.test")

    private static let page = #"""
    <html><body>
      <a href="https://example.com/next">Next page</a>
      <button id="b" onclick="document.title='clicked'">Do it</button>
      <button style="display:none">Hidden</button>
      <form id="search" method="get" role="search" action="/s">
        <input id="q" type="search" aria-label="Search">
      </form>
      <form id="login" method="post" action="/login">
        <input id="user" name="user" placeholder="Email">
        <input id="pw" type="password" placeholder="Password">
        <button type="submit">Sign in</button>
      </form>
      <select id="size"><option value="s">Small</option><option value="l">Large</option></select>
      <input id="tracked" placeholder="Tracked">
      <p>Hello agent</p>
      <script>
        // A React-style tracker: a plain `el.value =` from the page's own
        // world updates this shadow, so the change event would read as no-op.
        window.seen = [];
        const t = document.getElementById('tracked');
        t.addEventListener('input', () => window.seen.push(t.value));
        document.getElementById('login').addEventListener('submit', e => { e.preventDefault(); document.title = 'submitted'; });
        document.getElementById('search').addEventListener('submit', e => { e.preventDefault(); document.title = 'searched:' + document.getElementById('q').value; });
        // The page tries to see or forge the agent's refs.
        window.__chordAgent = { refs: 'forged' };
      </script>
    </body></html>
    """#

    private func loadedWebView() async throws -> WKWebView {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 1200))
        web.loadHTMLString(Self.page, baseURL: URL(string: "https://example.com/"))
        for _ in 0..<100 {
            // Not `readyState`: the initial about:blank already reads "complete".
            let ready = (try? await web.evaluateJavaScript(
                "document.readyState === 'complete' && !!document.getElementById('tracked')"
            )) as? Bool
            if ready == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        return web
    }

    private func perform(_ request: AgentPageRequest, _ web: WKWebView) async throws -> [String: Any] {
        let json = try #require(await AgentPageScript.run(request, in: web, world: world))
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func elements(_ web: WKWebView) async throws -> [[String: Any]] {
        try #require(try await perform(.listElements(limit: 100), web)["elements"] as? [[String: Any]])
    }

    private func ref(named name: String, in list: [[String: Any]]) throws -> String {
        try #require(list.first { ($0["name"] as? String) == name }?["ref"] as? String)
    }

    @Test("Lists visible interactive elements with roles and labels, never a password value")
    func listsElements() async throws {
        let web = try await loadedWebView()
        _ = try await web.evaluateJavaScript("document.getElementById('pw').value = 'hunter2'")
        let list = try await elements(web)
        let names = list.compactMap { $0["name"] as? String }
        #expect(names.contains("Next page"))
        #expect(names.contains("Do it"))
        #expect(names.contains("Search"))
        #expect(!names.contains("Hidden"))
        #expect(list.first { $0["name"] as? String == "Next page" }?["role"] as? String == "link")
        let password = try #require(list.first { $0["type"] as? String == "password" })
        #expect(password["value"] == nil)
        #expect(!String(describing: list).contains("hunter2"))
    }

    @Test("Refs are stable across listings and invisible to the page")
    func refsAreStableAndPrivate() async throws {
        let web = try await loadedWebView()
        let first = try ref(named: "Do it", in: try await elements(web))
        let second = try ref(named: "Do it", in: try await elements(web))
        #expect(first == second)
        // The page's own `window.__chordAgent` is its forgery, untouched.
        #expect(try await web.evaluateJavaScript("window.__chordAgent.refs") as? String == "forged")
    }

    @Test("Click reaches the page's own handler")
    func clicks() async throws {
        let web = try await loadedWebView()
        let button = try ref(named: "Do it", in: try await elements(web))
        #expect(try await perform(.click(ref: button), web)["ok"] as? Bool == true)
        let title = try await web.evaluateJavaScript("document.title") as? String
        #expect(title == "clicked")
    }

    @Test("Typing fires input events the page sees, with the full value")
    func types() async throws {
        let web = try await loadedWebView()
        let field = try ref(named: "Tracked", in: try await elements(web))
        let result = try await perform(.type(ref: field, text: "hello", clear: true, submit: false), web)
        #expect(result["value"] as? String == "hello")
        let seen = try await web.evaluateJavaScript("window.seen.join(',')") as? String
        #expect(seen == "hello")
    }

    @Test("Password fields are refused")
    func refusesPasswords() async throws {
        let web = try await loadedWebView()
        let password = try ref(named: "Password", in: try await elements(web))
        let result = try await perform(.type(ref: password, text: "x", clear: true, submit: false), web)
        #expect(result["ok"] as? Bool == false)
        #expect(result["error"] as? String == "password_field")
        #expect(try await web.evaluateJavaScript("document.getElementById('pw').value") as? String == "")
    }

    @Test("Submit goes through the form, so its handler runs")
    func submits() async throws {
        let web = try await loadedWebView()
        let search = try ref(named: "Search", in: try await elements(web))
        _ = try await perform(.type(ref: search, text: "chord", clear: true, submit: true), web)
        #expect(try await web.evaluateJavaScript("document.title") as? String == "searched:chord")
    }

    @Test("Describe reports the form a control would submit")
    func describesForms() async throws {
        let web = try await loadedWebView()
        let list = try await elements(web)
        let signIn = try await perform(.describe(ref: try ref(named: "Sign in", in: list)), web)
        #expect(signIn["is_submit"] as? Bool == true)
        let form = try #require(signIn["form"] as? [String: Any])
        #expect(form["method"] as? String == "post")
        #expect(form["has_password"] as? Bool == true)

        let search = try await perform(.describe(ref: try ref(named: "Search", in: list)), web)
        let searchForm = try #require(search["form"] as? [String: Any])
        #expect(searchForm["is_search"] as? Bool == true)
        #expect(searchForm["method"] as? String == "get")
    }

    @Test("Describe notices a filled password anywhere on the page")
    func describesFilledPassword() async throws {
        let web = try await loadedWebView()
        let list = try await elements(web)
        let button = try ref(named: "Do it", in: list)
        #expect(try await perform(.describe(ref: button), web)["password_filled"] as? Bool == false)
        _ = try await web.evaluateJavaScript("document.getElementById('pw').value = 'secret'")
        #expect(try await perform(.describe(ref: button), web)["password_filled"] as? Bool == true)
    }

    @Test("Select options are picked by visible text")
    func selectsOptions() async throws {
        let web = try await loadedWebView()
        let list = try await elements(web)
        let select = try #require(list.first { $0["role"] as? String == "combobox" }?["ref"] as? String)
        _ = try await perform(.type(ref: select, text: "Large", clear: true, submit: false), web)
        #expect(try await web.evaluateJavaScript("document.getElementById('size').value") as? String == "l")
        let missing = try await perform(.type(ref: select, text: "Huge", clear: true, submit: false), web)
        #expect(missing["error"] as? String == "no_such_option")
    }

    @Test("An unknown or stale ref is reported, not acted on")
    func staleRef() async throws {
        let web = try await loadedWebView()
        let button = try ref(named: "Do it", in: try await elements(web))
        _ = try await web.evaluateJavaScript("document.getElementById('b').remove()")
        #expect(try await perform(.click(ref: button), web)["error"] as? String == "stale_ref")
        #expect(try await perform(.click(ref: "e9999"), web)["error"] as? String == "stale_ref")
    }

    @Test("Find text and scroll report what they saw")
    func findAndScroll() async throws {
        let web = try await loadedWebView()
        #expect(try await perform(.findText("hello AGENT"), web)["found"] as? Bool == true)
        #expect(try await perform(.findText("absent"), web)["found"] as? Bool == false)
        #expect(try await perform(.scroll(ref: nil, pages: 1), web)["ok"] as? Bool == true)
    }
}
