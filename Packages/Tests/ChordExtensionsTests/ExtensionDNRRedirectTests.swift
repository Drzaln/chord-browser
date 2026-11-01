import ChordCore
import ChordTestSupport
import Foundation
import Testing
import WebKit

@testable import ChordEngine
@testable import ChordExtensions

/// M9d: extension pages in tabs, and a declarativeNetRequest redirect end to
/// end, the way Norma uses one. WebKit serves an extension's page only to a
/// view built from that extension's configuration, so the engine moves the
/// pane to such a view and back to a web one when the page returns to a site.
@Suite("Extension pages in tabs", .serialized)
@MainActor
struct ExtensionDNRRedirectTests {

    private struct Fixture {
        let engine: WebKitEngine
        let host: WebKitExtensionHost
        let space: Space
        let id: String
        let blocked: URL
        let allowed: URL
        let server: TestHTTPServer
        let dir: URL
    }

    private func makeFixture(exposedTo matches: String = "<all_urls>") async throws -> Fixture {
        let server = try TestHTTPServer(routes: [
            .init(path: "/blocked", html: "<body>blocked site</body>"),
            .init(path: "/allowed", html: "<body>allowed</body>"),
        ])
        try await server.start()
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ext-dnr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
            { "manifest_version": 3, "name": "Redirect", "version": "1.0",
              "permissions": ["declarativeNetRequest"],
              "host_permissions": ["<all_urls>"],
              "web_accessible_resources": [{ "resources": ["landing.html"], "matches": ["\(matches)"] }],
              "declarative_net_request": { "rule_resources": [
                { "id": "rules", "enabled": true, "path": "rules.json" }
              ] } }
            """.write(to: dir.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        // Norma's shape: a file and a fragment naming the site, which WebKit
        // escapes into the path.
        try """
            [{ "id": 1, "priority": 1,
               "action": { "type": "redirect", "redirect": { "extensionPath": "/landing.html#site" } },
               "condition": { "urlFilter": "/blocked", "resourceTypes": ["main_frame"] } }]
            """.write(to: dir.appending(path: "rules.json"), atomically: true, encoding: .utf8)
        try "<!doctype html><body>landing</body>".write(
            to: dir.appending(path: "landing.html"), atomically: true, encoding: .utf8
        )
        try "<!doctype html><body>options</body>".write(
            to: dir.appending(path: "options.html"), atomically: true, encoding: .utf8
        )

        let host = WebKitExtensionHost()
        let space = Space(name: "Focus", sortIndex: 0)
        let id = String(repeating: "b", count: 32)
        _ = try await host.load(
            InstalledExtension(slug: "redirect", identifier: id, resourceURL: dir), in: space
        )
        host.setAllHostsAccess(true, slug: "redirect", in: space)
        let engine = WebKitEngine(
            configuration: EngineConfiguration(
                faviconCacheDirectory: FileManager.default.temporaryDirectory
                    .appending(path: "engine-\(UUID().uuidString)")
            )
        )
        engine.extensionControllerProvider = host
        return Fixture(
            engine: engine, host: host, space: space, id: id,
            blocked: await server.url("blocked"), allowed: await server.url("allowed"),
            server: server, dir: dir
        )
    }

    private func cleanUp(_ fixture: Fixture) async {
        await fixture.server.stop()
        try? FileManager.default.removeItem(at: fixture.dir)
    }

    /// Waits until the pane's current view settles on a URL that passes.
    private func settle(
        _ engine: WebKitEngine, _ paneID: UUID, _ check: (URL?) -> Bool
    ) async throws -> URL? {
        var url: URL?
        for _ in 0..<100 {
            let web = engine.pool.peek(paneID)?.webView
            url = web?.url
            if check(url), web?.isLoading == false { return url }
            try await Task.sleep(for: .milliseconds(50))
        }
        return url
    }

    private func text(_ engine: WebKitEngine, _ paneID: UUID) async throws -> String? {
        try await engine.pool.peek(paneID)?.webView
            .evaluateJavaScript("document.body.innerText") as? String
    }

    @Test("A rule's redirect lands on the extension's page, and its page sends the tab back")
    func redirectAndReturn() async throws {
        let fixture = try await makeFixture()
        defer { Task { await cleanUp(fixture) } }
        let engine = fixture.engine
        let pane = Pane(url: fixture.allowed)
        let surface = engine.surface(for: pane, in: fixture.space)
        _ = try await settle(engine, pane.id) { $0?.path == "/allowed" }

        engine.load(fixture.blocked, in: pane.id)
        let landed = try await settle(engine, pane.id) { $0?.path == "/landing.html" }
        #expect(landed?.host == fixture.id)
        #expect(landed?.fragment == "site", "the escaped fragment is put back")
        #expect(try await text(engine, pane.id) == "landing")
        #expect(engine.surface(for: pane, in: fixture.space) == surface, "same container")

        // The page's "continue anyway": back to the web, in a web view again.
        _ = try await engine.pool.peek(pane.id)?.webView.evaluateJavaScript(
            "location.href = '\(fixture.allowed.absoluteString)'; 0"
        )
        let back = try await settle(engine, pane.id) { $0?.path == "/allowed" }
        #expect(back == fixture.allowed)
        #expect(try await text(engine, pane.id) == "allowed")
        #expect(engine.pool.peek(pane.id)?.extensionHost == nil)
    }

    @Test("A tab opened on an extension's page shows it")
    func extensionPageInATab() async throws {
        let fixture = try await makeFixture()
        defer { Task { await cleanUp(fixture) } }
        let url = try #require(URL(string: "chrome-extension://\(fixture.id)/options.html"))
        let pane = Pane(url: url)
        _ = fixture.engine.surface(for: pane, in: fixture.space)

        let shown = try await settle(fixture.engine, pane.id) { $0?.path == "/options.html" }
        #expect(shown == url)
        #expect(try await text(fixture.engine, pane.id) == "options")
    }

    @Test("A site the manifest doesn't expose the page to can't open it")
    func unexposedSiteIsRefused() async throws {
        let fixture = try await makeFixture(exposedTo: "https://elsewhere.example/*")
        defer { Task { await cleanUp(fixture) } }
        let engine = fixture.engine
        let pane = Pane(url: fixture.allowed)
        _ = engine.surface(for: pane, in: fixture.space)
        _ = try await settle(engine, pane.id) { $0?.path == "/allowed" }

        _ = try await engine.pool.peek(pane.id)?.webView.evaluateJavaScript(
            "location.href = 'chrome-extension://\(fixture.id)/landing.html'; 0"
        )
        try await Task.sleep(for: .milliseconds(500))
        #expect(engine.pool.peek(pane.id)?.extensionHost == nil)
        // The tab says what was refused rather than going quiet (cta), as
        // Chrome's blocked page does.
        let text = try await engine.pool.peek(pane.id)?.webView.evaluateJavaScript(
            "document.body ? document.body.innerText : ''"
        ) as? String
        #expect(text?.contains("can’t be opened here") == true, "\(text ?? "nil")")
        #expect(text?.contains("chrome-extension://\(fixture.id)/landing.html") == true)
    }
}
