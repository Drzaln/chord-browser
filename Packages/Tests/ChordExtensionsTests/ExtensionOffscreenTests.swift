import Foundation
import Testing
import WebKit

@testable import ChordExtensions
@testable import ChordCore

/// M8: a real offscreen page is created through the shim endpoint, belongs to
/// the Space's extension, and can be closed again.
@MainActor
struct ExtensionOffscreenTests {
    private func installedExtension() throws -> (InstalledExtension, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "chord-offscreen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = """
            { "manifest_version": 3, "name": "Offscreen Test", "version": "1.0",
              "permissions": ["offscreen"] }
            """
        try manifest.write(
            to: dir.appending(path: "manifest.json"), atomically: true, encoding: .utf8
        )
        try "<!doctype html><html><head></head><body>offscreen</body></html>"
            .write(to: dir.appending(path: "offscreen.html"), atomically: true, encoding: .utf8)
        try ExtensionShims.prepare(dir, fresh: true)
        return (
            InstalledExtension(
                slug: "offscreen-test",
                identifier: String(repeating: "a", count: 32),
                resourceURL: dir
            ),
            { try? FileManager.default.removeItem(at: dir) }
        )
    }

    @Test func createsAndClosesAnOffscreenDocument() async throws {
        let host = WebKitExtensionHost()
        let (installed, cleanup) = try installedExtension()
        defer { cleanup() }
        let space = Space(name: "Work", sortIndex: 0)
        try await host.load(installed, in: space)
        let context = try #require(host.context(forSlug: installed.slug, in: space))

        let create = try await ExtensionShimBroker.answer(
            ["api": "offscreen.createDocument",
             "args": [["url": "offscreen.html", "reasons": ["DOM_PARSER"]]]],
            context: context,
            spaceID: space.id
        )
        #expect((create as? [String: Any])?["error"] == nil)
        #expect(ExtensionOffscreen.hasDocument(
            identifier: installed.identifier, spaceID: space.id
        ))
        let web = try #require(ExtensionOffscreen.webView(
            identifier: installed.identifier, spaceID: space.id
        ))
        let kind = try await web.evaluateJavaScript("typeof chrome.offscreen")
        #expect(kind as? String == "object")
        let has = try await web.callAsyncJavaScript(
            "return await chrome.offscreen.hasDocument();",
            arguments: [:], in: nil, contentWorld: .page
        )
        #expect(has as? Bool == true)

        _ = try await ExtensionShimBroker.answer(
            ["api": "offscreen.closeDocument", "args": []],
            context: context,
            spaceID: space.id
        )
        #expect(!ExtensionOffscreen.hasDocument(
            identifier: installed.identifier, spaceID: space.id
        ))
    }
}
