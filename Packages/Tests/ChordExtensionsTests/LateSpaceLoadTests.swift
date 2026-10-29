import ChordCore
import ChordTestSupport
import Foundation
import Testing
import WebKit

@testable import ChordExtensions

/// A Space's extensions load the first time a window shows it (c1k.2), so its
/// tabs can be open (restored, or routed in by a rule) before its extensions
/// are. Those pages hold the Space's controller from creation, and loading the
/// context then must still reach them with its content scripts.
@Suite("Late Space load")
@MainActor
struct LateSpaceLoadTests {

    @Test("A content script reaches a page opened before its Space loaded")
    func contentScriptReachesAnOpenPage() async throws {
        let server = try TestHTTPServer(routes: [
            .init(path: "/page", html: "<body>page</body>")
        ])
        try await server.start()
        let pageURL = await server.url("page")
        defer { Task { await server.stop() } }

        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ext-late-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
            { "manifest_version": 3, "name": "Late", "version": "1.0",
              "host_permissions": ["<all_urls>"],
              "content_scripts": [{ "matches": ["<all_urls>"], "js": ["content.js"] }] }
            """.write(to: dir.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try "document.body.dataset.cs = '1';".write(
            to: dir.appending(path: "content.js"), atomically: true, encoding: .utf8
        )

        let host = WebKitExtensionHost()
        let space = Space(name: "Later", sortIndex: 0)
        // The engine prepares the (empty) controller when it builds a view.
        _ = host.prepare(space)
        let configuration = WKWebViewConfiguration()
        configuration.webExtensionController = try #require(host.controllers[space.id])
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: pageURL))
        for _ in 0..<60 {
            let ready = try? await webView.evaluateJavaScript("document.readyState") as? String
            if ready == "complete", webView.url?.path == "/page" { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        _ = try await host.load(InstalledExtension(slug: "late", resourceURL: dir), in: space)
        host.setAllHostsAccess(true, slug: "late", in: space)

        var marker: String?
        for _ in 0..<60 {
            marker = try? await webView.evaluateJavaScript("document.body.dataset.cs ?? null") as? String
            if marker == "1" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(marker == "1")
    }
}
