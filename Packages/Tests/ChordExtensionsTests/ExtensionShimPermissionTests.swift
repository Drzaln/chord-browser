import Foundation
import Testing
import WebKit

@testable import ChordExtensions
@testable import ChordCore

/// M9a tails: Search-answered permissions go through the same sheet as WebKit
/// permissions and are remembered per extension.
@MainActor
struct ExtensionShimPermissionTests {
    private func makeContext(
        identifier: String = String(repeating: "a", count: 32)
    ) async throws -> (WebKitExtensionHost, WKWebExtensionContext, Space, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "chord-shim-perm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = """
            { "manifest_version": 3, "name": "Permission Test", "version": "1.0",
              "permissions": ["history", "bookmarks"] }
            """
        try manifest.write(
            to: dir.appending(path: "manifest.json"), atomically: true, encoding: .utf8
        )
        let host = WebKitExtensionHost()
        let space = Space(name: "Work", sortIndex: 0)
        let installed = InstalledExtension(
            slug: "permission-test", identifier: identifier, resourceURL: dir
        )
        try await host.load(installed, in: space)
        let context = try #require(host.context(forSlug: installed.slug, in: space))
        return (host, context, space, dir)
    }

    @Test func storeApiWithoutItsManifestPermissionIsRefused() async throws {
        let (_, context, space, dir) = try await makeContext()
        defer { try? FileManager.default.removeItem(at: dir) }
        let answer = try await ExtensionShimBroker.answer(
            ["api": "downloads.search", "args": [[]]],
            context: context, spaceID: space.id
        ) as? [String: Any]
        #expect((answer?["error"] as? String)?.contains("downloads") == true)
    }

    @Test func shimPermissionIsAskedAndRemembered() async throws {
        let (host, context, _, dir) = try await makeContext()
        defer {
            host.removeShimPermissions(["history"], context: context)
            try? FileManager.default.removeItem(at: dir)
        }
        host.removeShimPermissions(["history", "bookmarks"], context: context)
        var asked: PermissionRequest?
        host.onPermissionRequest = { request in
            asked = request
            host.resolvePermission(id: request.id, allow: true)
        }

        let granted = await host.requestShimPermissions(["history"], context: context)
        #expect(granted)
        #expect(asked?.kind == .permission)
        #expect(asked?.items == ["history"])
        #expect(host.shimGranted(context) == ["history"])
    }

    @Test func denyingKeepsThePermissionOff() async throws {
        let (host, context, _, dir) = try await makeContext()
        defer { try? FileManager.default.removeItem(at: dir) }
        host.removeShimPermissions(["history", "bookmarks"], context: context)
        host.onPermissionRequest = { request in
            host.resolvePermission(id: request.id, allow: false)
        }

        let granted = await host.requestShimPermissions(["bookmarks"], context: context)
        #expect(!granted)
        #expect(host.shimGranted(context).isEmpty)
    }

    @Test func removingAGrantForgetsIt() async throws {
        let (host, context, _, dir) = try await makeContext()
        defer { try? FileManager.default.removeItem(at: dir) }
        host.removeShimPermissions(["history", "bookmarks"], context: context)
        host.onPermissionRequest = { request in
            host.resolvePermission(id: request.id, allow: true)
        }
        _ = await host.requestShimPermissions(["history"], context: context)
        #expect(host.shimGranted(context) == ["history"])
        host.removeShimPermissions(["history"], context: context)
        #expect(host.shimGranted(context).isEmpty)
    }
}

/// M9a tails: user scripts become injectable files with Chord's marker names.
struct ExtensionUserScriptTests {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "chord-us-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func inlineScriptBecomesAFile() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try ExtensionShimFiles.userScriptFile(
            [
                "id": "one",
                "js": [["code": "globalThis.ran = true;"]],
                "includeGlobs": ["https://example.com/*"],
            ],
            in: dir
        )
        #expect(path.hasPrefix("_chord/us-"))
        let text = try String(
            contentsOf: dir.appending(path: path), encoding: .utf8
        )
        #expect(text.contains("chord_user_script"))
        #expect(text.contains("__chordUserScript"))
        #expect(text.contains("globalThis.ran = true"))
    }

    @Test func savedScriptsRoundTripAndWorldsAreStored() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scripts: [[String: Any]] = [[
            "id": "one", "js": [["code": "1"]],
        ]]
        try ExtensionShimFiles.saveUserScripts(scripts, in: dir)
        #expect(ExtensionShimFiles.userScripts(in: dir).count == 1)

        try ExtensionShimFiles.saveWorld(["worldId": "w1", "csp": "script-src 'self'"], in: dir)
        #expect(ExtensionShimFiles.worlds(in: dir).first?["worldId"] as? String == "w1")
        try ExtensionShimFiles.saveWorld(["worldId": "w1", "reset": true], in: dir)
        #expect(ExtensionShimFiles.worlds(in: dir).isEmpty)
    }
}
