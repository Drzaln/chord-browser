import Foundation
import Testing
import WebKit

@testable import ChordEngine

/// `eval_js`'s world against real WebKit (0mu.3): what an agent's script can
/// see, what it cannot, and that a hung script cannot hang the tool.
@Suite("Agent eval script", .serialized)
@MainActor
struct AgentEvalScriptTests {
    private let world = WKContentWorld.world(name: "chord.agent.eval.test")

    private static let page = #"""
    <html><body>
      <h1 id="h">Hello</h1>
      <input id="user" value="ada">
      <input id="pw" type="password">
      <script>
        window.pageSecret = "page-world-only";
        try { localStorage.setItem("token", "abc"); } catch (e) {}
      </script>
    </body></html>
    """#

    private func loadedWebView() async throws -> WKWebView {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        web.loadHTMLString(Self.page, baseURL: URL(string: "https://example.com/"))
        for _ in 0..<100 {
            let ready = (try? await web.evaluateJavaScript(
                "document.readyState === 'complete' && !!document.getElementById('h')"
            )) as? Bool
            if ready == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        return web
    }

    private func run(_ script: String, _ web: WKWebView, timeout: Duration = .seconds(5)) async -> AgentEvalOutcome {
        await AgentEvalScript.run(script, in: web, world: world, timeout: timeout)
    }

    @Test("Returns the script's value as JSON, and reads the DOM")
    func returnsValues() async throws {
        let web = try await loadedWebView()
        #expect(await run("return document.getElementById('h').textContent;", web) == .value(#""Hello""#))
        #expect(await run("return { n: 2, list: [1, 'a'] };", web) == .value(#"{"n":2,"list":[1,"a"]}"#))
        #expect(await run("const x = 1;", web) == .value("null"))
        #expect(await run("return await new Promise(r => setTimeout(() => r(7), 10));", web) == .value("7"))
    }

    @Test("A throw comes back as its message")
    func throwsMessage() async throws {
        let web = try await loadedWebView()
        guard case .threw(let message) = await run("throw new Error('nope');", web) else {
            Issue.record("expected a throw")
            return
        }
        #expect(message.contains("nope"))
    }

    @Test("Page-world globals are invisible")
    func isolatedFromPage() async throws {
        let web = try await loadedWebView()
        #expect(await run("return typeof window.pageSecret;", web) == .value(#""undefined""#))
    }

    @Test("Cookies read empty and storage throws")
    func hidesCookiesAndStorage() async throws {
        let web = try await loadedWebView()
        _ = try await web.evaluateJavaScript("document.cookie = 'session=s3cret; path=/'")
        #expect(await run("return document.cookie;", web) == .value(#""""#))
        // The original can't be put back: the override is non-configurable.
        #expect(await run(#"""
            try { Object.defineProperty(Document.prototype, "cookie", { get() { return "x"; } }); } catch (e) {}
            return document.cookie;
            """#, web) == .value(#""""#))
        for name in ["localStorage", "sessionStorage", "indexedDB"] {
            guard case .threw(let message) = await run("return \(name).length;", web) else {
                Issue.record("\(name) should throw")
                continue
            }
            #expect(message.contains(name))
        }
    }

    @Test("Password values read empty, refuse writes, and a filled one stops the run")
    func passwords() async throws {
        let web = try await loadedWebView()
        #expect(await run("return document.getElementById('user').value;", web) == .value(#""ada""#))
        guard case .threw = await run("document.getElementById('pw').value = 'x';", web) else {
            Issue.record("writing a password should throw")
            return
        }
        // Nothing in the world hands out the native getter.
        #expect(await run(#"""
            const found = Object.getOwnPropertyNames(window).filter(n => n.startsWith("__chord"));
            return found.map(n => typeof window[n]);
            """#, web) == .value(#"["function"]"#))

        // The user (page world) types a password: no script runs at all.
        _ = try await web.evaluateJavaScript("document.getElementById('pw').value = 'hunter2'")
        #expect(await run("return 1;", web) == .passwordFilled)
    }

    @Test("A script that never settles times out instead of hanging")
    func timesOut() async throws {
        let web = try await loadedWebView()
        let start = ContinuousClock.now
        #expect(await run("await new Promise(() => {});", web, timeout: .milliseconds(300)) == .timedOut)
        #expect(ContinuousClock.now - start < .seconds(3))
    }
}
