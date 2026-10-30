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

    @Test("Allowing an extension on one page allows its site, not just that URL (1mm.16)")
    func pageAllowCoversSite() async throws {
        let (host, _, context, cleanup) = try await load("""
            { "manifest_version": 3, "name": "Page", "version": "1",
              "optional_host_permissions": ["https://*.youtube.com/*", "https://www.reddit.com/*"] }
            """)
        defer { cleanup() }
        var asked: [PermissionRequest] = []
        host.onPermissionRequest = { asked.append($0) }
        let controller = try #require(context.webExtensionController)
        let video = try #require(URL(string: "https://www.youtube.com/watch?v=one"))
        var answered: Set<URL>?
        host.webExtensionController(
            controller, promptForPermissionToAccess: [video], in: nil, for: context
        ) { urls, _ in answered = urls }

        let request = try #require(asked.first)
        #expect(request.kind == .matchPattern)
        #expect(request.items == ["https://www.youtube.com/*"])
        host.resolvePermission(id: request.id, allow: true)

        #expect(answered == [video])
        let next = try #require(URL(string: "https://www.youtube.com/watch?v=two"))
        #expect(granted(context.permissionStatus(for: next)))
        let elsewhere = try #require(URL(string: "https://www.reddit.com/"))
        #expect(!granted(context.permissionStatus(for: elsewhere)))
    }

    @Test("A page question about a file or another extension's page offers no site")
    func pageAllowSkipsWithheld() {
        let urls: Set<URL> = [
            URL(string: "file:///Users/me/a.html")!,
            URL(string: "chrome-extension://abc/page.html")!,
            URL(string: "https://Example.com/a?b=c")!,
            URL(string: "https://example.com/d")!,
        ]
        #expect(ExtensionGrants.sitePatterns(for: urls).map(\.string) == ["https://example.com/*"])
    }

    @Test("One that wants every site is asked once, for every site; repeats wait on that sheet")
    func everySiteAskedOnce() async throws {
        let (host, _, context, cleanup) = try await load("""
            { "manifest_version": 3, "name": "All", "version": "1",
              "optional_host_permissions": ["<all_urls>"] }
            """)
        defer { cleanup() }
        var asked: [PermissionRequest] = []
        host.onPermissionRequest = { asked.append($0) }
        let controller = try #require(context.webExtensionController)
        var answers: [Set<URL>] = []
        for page in ["https://www.google.com/", "https://github.com/", "https://example.com/"] {
            let url = try #require(URL(string: page))
            host.webExtensionController(
                controller, promptForPermissionToAccess: [url], in: nil, for: context
            ) { urls, _ in answers.append(urls) }
        }
        #expect(asked.count == 1)
        #expect(asked.first?.items == ["*://*/*"])
        host.resolvePermission(id: try #require(asked.first).id, allow: true)
        #expect(answers.count == 3 && answers.allSatisfy { $0.count == 1 })
        #expect(granted(context.permissionStatus(for: URL(string: "https://www.reddit.com/")!)))
    }

    @Test("Don't Allow holds for the session: the same question isn't put again")
    func refusalHolds() async throws {
        let (host, _, context, cleanup) = try await load("""
            { "manifest_version": 3, "name": "Page", "version": "1",
              "optional_host_permissions": ["https://*.youtube.com/*"] }
            """)
        defer { cleanup() }
        var asked: [PermissionRequest] = []
        host.onPermissionRequest = { asked.append($0) }
        let controller = try #require(context.webExtensionController)
        let video = try #require(URL(string: "https://www.youtube.com/watch?v=one"))
        host.webExtensionController(
            controller, promptForPermissionToAccess: [video], in: nil, for: context
        ) { _, _ in }
        host.resolvePermission(id: try #require(asked.first).id, allow: false)

        var again: Set<URL>?
        host.webExtensionController(
            controller, promptForPermissionToAccess: [video], in: nil, for: context
        ) { urls, _ in again = urls }
        #expect(asked.count == 1)
        #expect(again == [])
    }
}
