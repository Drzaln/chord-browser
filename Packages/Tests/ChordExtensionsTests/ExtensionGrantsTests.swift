import ChordCore
import Foundation
import Testing
import WebKit

@testable import ChordExtensions

/// What a context is given at load beyond its declared API permissions, and
/// what it never gets (ported from Search, 1mm.6.2).
@Suite("Extension load grants")
@MainActor
struct ExtensionGrantsTests {

    /// Explicit, or implied by a broader grant (a site under *://*/*).
    private func granted(_ status: WKWebExtensionContext.PermissionStatus) -> Bool {
        status == .grantedExplicitly || status == .grantedImplicitly
    }

    private func load(
        _ manifest: String, identifier: String = "abcdefghijklmnopabcdefghijklmnop",
        inPrivateSpace: Bool = false
    ) async throws -> (WebKitExtensionHost, Space, WKWebExtensionContext, () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ext-grants-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try manifest.write(to: dir.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        let host = WebKitExtensionHost()
        let space = Space(name: "Work", sortIndex: 0, isPrivate: inPrivateSpace)
        let installed = InstalledExtension(slug: "grants", identifier: identifier, resourceURL: dir)
        try await host.load(installed, in: space)
        let context = try #require(host.context(forSlug: "grants", in: space))
        return (host, space, context, { try? FileManager.default.removeItem(at: dir) })
    }

    @Test("declarativeNetRequest also gets host access, or WebKit drops its redirects")
    func dnrGetsHostAccess() async throws {
        let (_, _, context, cleanup) = try await load("""
            { "manifest_version": 3, "name": "DNR", "version": "1",
              "permissions": ["declarativeNetRequest"] }
            """)
        defer { cleanup() }
        #expect(granted(context.permissionStatus(for: .declarativeNetRequestWithHostAccess)))
    }

    @Test("Without declarativeNetRequest, no host-access variant is granted")
    func noDNRNoHostAccess() async throws {
        let (_, _, context, cleanup) = try await load("""
            { "manifest_version": 3, "name": "Plain", "version": "1", "permissions": ["storage"] }
            """)
        defer { cleanup() }
        #expect(!granted(context.permissionStatus(for: .declarativeNetRequestWithHostAccess)))
    }

    @Test("identity can see its own sign-in address, and nothing else on that host")
    func identitySeesItsSignInAddress() async throws {
        let id = "abcdefghijklmnopabcdefghijklmnop"
        let (_, _, context, cleanup) = try await load("""
            { "manifest_version": 3, "name": "Auth", "version": "1", "permissions": ["identity"] }
            """, identifier: id)
        defer { cleanup() }
        let own = URL(string: "https://\(id).chromiumapp.org/done?code=1")!
        let other = URL(string: "https://someoneelse.chromiumapp.org/")!
        #expect(granted(context.permissionStatus(for: own)))
        #expect(!granted(context.permissionStatus(for: other)))
    }

    @Test("All sites never includes other extensions' pages or files")
    func fenceKeepsExtensionsAndFilesOut() async throws {
        let (host, space, context, cleanup) = try await load("""
            { "manifest_version": 3, "name": "Everywhere", "version": "1",
              "host_permissions": ["<all_urls>"] }
            """)
        defer { cleanup() }

        host.setAllHostsAccess(true, slug: "grants", in: space)

        #expect(granted(context.permissionStatus(for: URL(string: "https://example.com/")!)))
        #expect(host.hasAllHostsAccess(slug: "grants", in: space))
        // Extension pages and files are refused outright. Their status can't
        // be asked by pattern (chrome-extension://*/* reads "granted
        // implicitly" even when refused: it covers the extension's own
        // pages), so the refusals are read back directly.
        let denied = Set(context.deniedPermissionMatchPatterns.keys.map(\.string))
        #expect(denied.isSuperset(of: [
            "chrome-extension://*/*", "webkit-extension://*/*", "file:///*", "file://*/*",
        ]))
        // And <all_urls> is held as what it means for websites.
        #expect(context.grantedPermissionMatchPatterns.keys.map(\.string) == ["*://*/*"])
        #expect(!granted(context.permissionStatus(for: URL(string: "chrome-extension://other/page.html")!)))
        #expect(!granted(context.permissionStatus(for: URL(string: "file:///Users/me/secret.txt")!)))
    }

    @Test("Extension and file patterns are withheld; web patterns are not")
    func withheldPatterns() throws {
        func pattern(_ string: String) throws -> WKWebExtension.MatchPattern {
            try WKWebExtension.MatchPattern(string: string)
        }
        #expect(ExtensionGrants.withheld(try pattern("chrome-extension://*/*")))
        #expect(ExtensionGrants.withheld(try pattern("file:///*")))
        #expect(!ExtensionGrants.withheld(try pattern("https://example.com/*")))
        #expect(!ExtensionGrants.withheld(try pattern("<all_urls>")))
    }

    @Test("In a private Space an extension sees private pages, unless its manifest refuses")
    func privateDataAccess() async throws {
        let plain = #"{ "manifest_version": 3, "name": "P", "version": "1" }"#
        let refusing = #"{ "manifest_version": 3, "name": "R", "version": "1", "incognito": "not_allowed" }"#

        let (_, _, regular, c1) = try await load(plain)
        defer { c1() }
        #expect(!regular.hasAccessToPrivateData)

        let (_, _, inPrivate, c2) = try await load(plain, inPrivateSpace: true)
        defer { c2() }
        #expect(inPrivate.hasAccessToPrivateData)

        let (_, _, refused, c3) = try await load(refusing, inPrivateSpace: true)
        defer { c3() }
        #expect(!refused.hasAccessToPrivateData)
    }
}
