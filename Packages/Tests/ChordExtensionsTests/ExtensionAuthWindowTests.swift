import ChordCore
import Foundation
import Testing

@testable import ChordExtensions

/// M9d: the OAuth redirect boundary and the native identity answers. No window
/// is opened here; the real flow is exercised by the app.
@MainActor
struct ExtensionAuthWindowTests {
    private let id = String(repeating: "a", count: 32)

    @Test func onlyTheExtensionsOwnChromeRedirectIsAccepted() {
        #expect(ExtensionAuthWindow.isRedirect(
            URL(string: "https://\(id).chromiumapp.org/")!, extensionID: id
        ))
        #expect(ExtensionAuthWindow.isRedirect(
            URL(string: "https://\(id).chromiumapp.org/oauth/cb?code=x&state=y")!,
            extensionID: id
        ))
        #expect(!ExtensionAuthWindow.isRedirect(
            URL(string: "https://\(id).chromiumapp.org.evil.example/cb")!,
            extensionID: id
        ))
        #expect(!ExtensionAuthWindow.isRedirect(
            URL(string: "http://\(id).chromiumapp.org/cb")!, extensionID: id
        ))
        #expect(!ExtensionAuthWindow.isRedirect(
            URL(string: "https://user:pass@\(id).chromiumapp.org/cb")!,
            extensionID: id
        ))
        #expect(!ExtensionAuthWindow.isRedirect(
            URL(string: "https://\(String(repeating: "b", count: 32)).chromiumapp.org/cb")!,
            extensionID: id
        ))
    }

    @Test func identityNeedsItsManifestPermissionAndAWebURL() async throws {
        let (host, space, installed, cleanup) = try await loadedExtension(
            permissions: ["identity"]
        )
        defer { cleanup() }
        let context = try #require(host.context(forSlug: installed.slug, in: space))

        let refused = try await ExtensionShimBroker.answer(
            ["api": "identity.launchWebAuthFlow",
             "args": [["url": "ftp://example.com/auth"]]],
            context: context, spaceID: space.id, host: host
        ) as? [String: Any]
        #expect(refused?["error"] != nil)

        let profile = try await ExtensionShimBroker.answer(
            ["api": "identity.getProfileUserInfo", "args": []],
            context: context, spaceID: space.id, host: host
        ) as? [String: Any]
        let value = profile?["value"] as? [String: Any]
        #expect(value?["id"] as? String == "")
        #expect(value?["email"] as? String == "")
    }

    @Test func identityWithoutThePermissionIsRefused() async throws {
        let (host, space, installed, cleanup) = try await loadedExtension(permissions: [])
        defer { cleanup() }
        let context = try #require(host.context(forSlug: installed.slug, in: space))
        let refused = try await ExtensionShimBroker.answer(
            ["api": "identity.launchWebAuthFlow",
             "args": [["url": "https://example.com/auth"]]],
            context: context, spaceID: space.id, host: host
        ) as? [String: Any]
        #expect((refused?["error"] as? String)?.contains("identity") == true)
    }

    private func loadedExtension(
        permissions: [String]
    ) async throws -> (WebKitExtensionHost, Space, InstalledExtension, () -> Void) {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "chord-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3,
            "name": "Auth Probe",
            "version": "1.0",
            "permissions": permissions,
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: folder.appending(path: "manifest.json"))
        try ExtensionShims.prepare(folder, fresh: true)
        let installed = InstalledExtension(
            slug: "auth-probe", identifier: id, resourceURL: folder
        )
        let host = WebKitExtensionHost()
        let space = Space(name: "Probe", sortIndex: 0)
        _ = try await host.load(installed, in: space)
        return (host, space, installed, { try? FileManager.default.removeItem(at: folder) })
    }
}
