import Foundation
import Testing
import WebKit

@testable import ChordExtensions
@testable import ChordCore

/// M9d: the shim's declarativeNetRequest transforms. Rules WebKit cannot take
/// are dropped, never widened: an extension-URL redirect becomes an
/// `extensionPath`, and resource types WebKit has no name for are removed.
@MainActor
struct ExtensionDNRTransformTests {
    private func extensionPage() async throws -> (WKWebView, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "chord-dnr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
            { "manifest_version": 3, "name": "DNR Test", "version": "1.0",
              "permissions": ["declarativeNetRequest", "offscreen"] }
            """.write(
                to: dir.appending(path: "manifest.json"), atomically: true, encoding: .utf8
            )
        try """
            <!doctype html><html><head></head><body>dnr</body></html>
            """.write(
                to: dir.appending(path: "probe.html"), atomically: true, encoding: .utf8
            )
        try ExtensionShims.prepare(dir, fresh: true)
        let host = WebKitExtensionHost()
        let space = Space(name: "Work", sortIndex: 0)
        let identifier = String(repeating: "a", count: 32)
        let installed = InstalledExtension(
            slug: "dnr-test", identifier: identifier, resourceURL: dir
        )
        try await host.load(installed, in: space)
        let context = try #require(host.context(forSlug: installed.slug, in: space))
        _ = try await ExtensionShimBroker.answer(
            ["api": "offscreen.createDocument",
             "args": [["url": "probe.html", "reasons": ["DOM_PARSER"]]]],
            context: context, spaceID: space.id, host: host
        )
        let web = try #require(ExtensionOffscreen.webView(
            identifier: identifier, spaceID: space.id
        ))
        return (web, dir)
    }

    @Test func redirectsToExtensionFilesBecomeExtensionPaths() async throws {
        let (web, dir) = try await extensionPage()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = String(repeating: "a", count: 32)

        _ = try await web.callAsyncJavaScript(
            """
            return await chrome.declarativeNetRequest.updateSessionRules({
              addRules: [{
                id: 1, priority: 1,
                action: { type: "redirect", redirect: {
                  url: "chrome-extension://\(id)/blocked.html#site"
                } },
                condition: {
                  urlFilter: "||example.com^",
                  resourceTypes: ["main_frame", "object", "webtransport"]
                }
              }]
            });
            """,
            arguments: [:], in: nil, contentWorld: .page
        )
        let rules = try await web.callAsyncJavaScript(
            "return await chrome.declarativeNetRequest.getSessionRules();",
            arguments: [:], in: nil, contentWorld: .page
        ) as? [[String: Any]] ?? []
        let rule = try #require(rules.first { ($0["id"] as? Int) == 1 })
        let action = try #require(rule["action"] as? [String: Any])
        let redirect = try #require(action["redirect"] as? [String: Any])
        #expect(redirect["extensionPath"] as? String == "/blocked.html#site")
        #expect(redirect["url"] == nil)
        let condition = try #require(rule["condition"] as? [String: Any])
        #expect(condition["resourceTypes"] as? [String] == ["main_frame"])
    }

    @Test func aRuleWithOnlyUnknownResourceTypesIsDropped() async throws {
        let (web, dir) = try await extensionPage()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await web.callAsyncJavaScript(
            """
            return await chrome.declarativeNetRequest.updateSessionRules({
              addRules: [
                { id: 2, priority: 1, action: { type: "block" },
                  condition: { urlFilter: "||object.example^", resourceTypes: ["object"] } },
                { id: 3, priority: 1, action: { type: "block" },
                  condition: { urlFilter: "||script.example^", resourceTypes: ["script"] } },
              ]
            });
            """,
            arguments: [:], in: nil, contentWorld: .page
        )
        let rules = try await web.callAsyncJavaScript(
            "return await chrome.declarativeNetRequest.getSessionRules();",
            arguments: [:], in: nil, contentWorld: .page
        ) as? [[String: Any]] ?? []
        #expect(!rules.contains { ($0["id"] as? Int) == 2 })
        #expect(rules.contains { ($0["id"] as? Int) == 3 })
    }
}
