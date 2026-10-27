import ChordCore
import Foundation
import Testing

@testable import ChordExtensions

/// M9d: pages listed by an extension get `chrome.runtime`; every other page
/// keeps WebKit's bare `browser.runtime`.
@MainActor
struct ExtensionExternalTests {
    private let id = String(repeating: "c", count: 32)

    @Test func chromeTakesOnlyPatternsChromeWould() {
        #expect(ExtensionExternal.allowed("https://claude.ai/*"))
        #expect(ExtensionExternal.allowed("https://*.example.com/path*"))
        #expect(ExtensionExternal.allowed("*://example.com/*"))
        #expect(!ExtensionExternal.allowed("*://*/*"))
        #expect(!ExtensionExternal.allowed("https://*.com/*"))
        #expect(!ExtensionExternal.allowed("https://www.google.com/*"))
        #expect(!ExtensionExternal.allowed("file:///tmp/*"))
        #expect(!ExtensionExternal.allowed("https://example.com"))
    }

    @Test func listingsKeepOnlyAllowedPatternsAndDropEmptyExtensions() {
        let found = ExtensionExternal.listings(from: [
            (id: id, manifest: [
                "externally_connectable": [
                    "matches": ["https://claude.ai/*", "*://*/*"],
                ],
            ]),
            (id: String(repeating: "d", count: 32), manifest: [
                "externally_connectable": ["matches": ["*://*/*"]],
            ]),
        ])
        #expect(found[id] == ["https://claude.ai/*"])
        #expect(found.count == 1)
    }

    @Test func scriptNamesTheListingAndRefusesUnlistedIds() throws {
        let script = try #require(
            ExtensionExternal.script(for: [id: ["https://claude.ai/*"]])
        )
        #expect(script.contains(id))
        #expect(script.contains("claude.ai"))
        #expect(script.contains("Receiving end does not exist"))
        #expect(ExtensionExternal.script(for: [:]) == nil)
    }

    @Test func hostReadsTheLoadedExtensionsListing() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "chord-external-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try """
            {
              "manifest_version": 3,
              "name": "External Probe",
              "version": "1.0",
              "externally_connectable": { "matches": ["https://claude.ai/*"] }
            }
            """.write(
                to: folder.appending(path: "manifest.json"), atomically: true, encoding: .utf8
            )
        try ExtensionShims.prepare(folder, fresh: true)

        let host = WebKitExtensionHost()
        let space = Space(name: "Probe", sortIndex: 0)
        #expect(host.externallyConnectableScript() == nil)

        _ = try await host.load(
            InstalledExtension(slug: "external-probe", identifier: id, resourceURL: folder),
            in: space
        )
        let loaded = try #require(host.externallyConnectableScript())
        #expect(loaded.contains(id))
        #expect(loaded.contains("claude.ai"))
    }
}
