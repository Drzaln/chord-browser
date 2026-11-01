import ChordCore
import ChordTestSupport
import Foundation
import Testing
import WebKit

@testable import ChordEngine
@testable import ChordExtensions

/// d0w: a cross-origin-isolated page (COOP same-origin + COEP require-corp,
/// as Speedometer 3 serves) makes WebKit swap to a new web process for the
/// navigation. In Chord it stayed blank: the document never committed.
@Suite("Cross-origin-isolated pages", .serialized)
@MainActor
struct CrossOriginIsolationTests {
    private func isolatedServer() async throws -> TestHTTPServer {
        let server = try TestHTTPServer(routes: [
            .init(
                path: "/iso",
                html: "<!doctype html><title>loading</title><script>document.title = 'iso ' + self.crossOriginIsolated;</script><body>isolated</body>",
                extraHeaders: [
                    "Cross-Origin-Opener-Policy": "same-origin",
                    "Cross-Origin-Embedder-Policy": "require-corp",
                ]
            ),
            .init(path: "/plain", html: "<!doctype html><title>plain</title><body>plain</body>"),
        ])
        try await server.start()
        return server
    }

    private func engine() -> WebKitEngine {
        WebKitEngine(configuration: EngineConfiguration(
            faviconCacheDirectory: FileManager.default.temporaryDirectory
                .appending(path: "engine-\(UUID().uuidString)")
        ))
    }

    private func title(_ engine: WebKitEngine, _ paneID: UUID, becomes prefix: String) async throws -> String? {
        var title: String?
        for _ in 0..<100 {
            title = engine.pool.peek(paneID)?.webView.title
            if title?.hasPrefix(prefix) == true { return title }
            try await Task.sleep(for: .milliseconds(100))
        }
        return title
    }

    @Test("It loads in a fresh tab")
    func loadsInAFreshTab() async throws {
        let server = try await isolatedServer()
        defer { Task { await server.stop() } }
        let engine = engine()
        let pane = Pane(url: await server.url("iso"))
        _ = engine.surface(for: pane, in: Space(name: "Plain", sortIndex: 0))
        #expect(try await title(engine, pane.id, becomes: "iso") == "iso true")
    }

    @Test("It loads after another page in the same tab")
    func loadsAfterAnotherPage() async throws {
        let server = try await isolatedServer()
        defer { Task { await server.stop() } }
        let engine = engine()
        let pane = Pane(url: await server.url("plain"))
        _ = engine.surface(for: pane, in: Space(name: "Plain", sortIndex: 0))
        _ = try await title(engine, pane.id, becomes: "plain")
        engine.pool.peek(pane.id)?.webView.load(URLRequest(url: await server.url("iso")))
        #expect(try await title(engine, pane.id, becomes: "iso") == "iso true")
    }

    @Test("It loads in a Space with an extension controller")
    func loadsWithExtensions() async throws {
        let server = try await isolatedServer()
        defer { Task { await server.stop() } }
        let dir = FileManager.default.temporaryDirectory.appending(path: "coi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
            { "manifest_version": 3, "name": "Content", "version": "1.0",
              "host_permissions": ["<all_urls>"],
              "content_scripts": [{ "matches": ["<all_urls>"], "js": ["c.js"] }] }
            """.write(to: dir.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try "void 0;".write(to: dir.appending(path: "c.js"), atomically: true, encoding: .utf8)
        try ExtensionShims.prepare(dir, fresh: true)
        let host = WebKitExtensionHost()
        let space = Space(name: "Ext", sortIndex: 0)
        _ = try await host.load(
            InstalledExtension(slug: "content", identifier: String(repeating: "d", count: 32), resourceURL: dir),
            in: space
        )
        host.setAllHostsAccess(true, slug: "content", in: space)
        let engine = engine()
        engine.extensionControllerProvider = host
        let pane = Pane(url: await server.url("iso"))
        _ = engine.surface(for: pane, in: space)
        #expect(try await title(engine, pane.id, becomes: "iso") == "iso true")
    }
}
