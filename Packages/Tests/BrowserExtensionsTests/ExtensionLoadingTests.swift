import BrowserCore
import Foundation
import Testing

@testable import BrowserExtensions

/// M7 phase 7.3a: loading a bundle into a Space's controller, MV3 only.
///
/// `WKWebExtension.extension(resourceBaseURL:)` reads a directory with a
/// `manifest.json` just as it reads a ZIP, so these tests write a synthetic
/// extension directory rather than building a ZIP — the host passes the URL
/// straight through, so a directory exercises the same path.
@MainActor
struct ExtensionLoadingTests {
    private func space() -> Space { Space(name: "Work", sortIndex: 0) }

    /// Writes a manifest into a fresh temp directory and returns an
    /// `InstalledExtension` pointing at it, plus a cleanup closure.
    private func installedExtension(
        slug: String,
        manifest: String
    ) throws -> (InstalledExtension, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try manifest.data(using: .utf8)!.write(to: dir.appending(path: "manifest.json"))
        return (
            InstalledExtension(slug: slug, resourceURL: dir),
            { try? FileManager.default.removeItem(at: dir) }
        )
    }

    private static let mv3 = """
        { "manifest_version": 3, "name": "Test MV3", "version": "1.0" }
        """
    private static let mv2 = """
        { "manifest_version": 2, "name": "Test MV2", "version": "1.0" }
        """

    @Test func loadsAnMV3ExtensionIntoTheSpaceController() async throws {
        let host = WebKitExtensionHost()
        let (installed, cleanup) = try installedExtension(slug: "test-mv3", manifest: Self.mv3)
        defer { cleanup() }
        let s = space()

        let loaded = try await host.load(installed, in: s)

        #expect(loaded.slug == "test-mv3")
        #expect(loaded.spaceID == s.id)
        #expect(loaded.manifestVersion == 3)
        // Loading prepares the Space's controller if it was not already.
        #expect(host.preparedSpaceIDs.contains(s.id))
        #expect(host.loadedExtensions(in: s).map(\.slug) == ["test-mv3"])
    }

    @Test func rejectsAnMV2Extension() async throws {
        let host = WebKitExtensionHost()
        let (installed, cleanup) = try installedExtension(slug: "test-mv2", manifest: Self.mv2)
        defer { cleanup() }
        let s = space()

        await #expect(throws: ExtensionLoadError.self) {
            try await host.load(installed, in: s)
        }
        // A rejected load leaves nothing loaded.
        #expect(host.loadedExtensions(in: s).isEmpty)
    }

    @Test func rejectsMV2WithTheRightCase() async throws {
        let host = WebKitExtensionHost()
        let (installed, cleanup) = try installedExtension(slug: "mv2", manifest: Self.mv2)
        defer { cleanup() }

        do {
            try await host.load(installed, in: space())
            Issue.record("expected MV2 to be rejected")
        } catch let ExtensionLoadError.unsupportedManifestVersion(version) {
            #expect(version == 2)
        }
    }

    @Test func unloadRemovesTheExtension() async throws {
        let host = WebKitExtensionHost()
        let (installed, cleanup) = try installedExtension(slug: "test-mv3", manifest: Self.mv3)
        defer { cleanup() }
        let s = space()

        try await host.load(installed, in: s)
        try host.unload(slug: "test-mv3", in: s)
        #expect(host.loadedExtensions(in: s).isEmpty)
    }

    @Test func unloadOfSomethingNotLoadedIsANoOp() throws {
        let host = WebKitExtensionHost()
        // Does not throw even though nothing is loaded in this Space.
        try host.unload(slug: "nope", in: space())
    }

    @Test func loadsAreIsolatedPerSpace() async throws {
        let host = WebKitExtensionHost()
        let (installed, cleanup) = try installedExtension(slug: "test-mv3", manifest: Self.mv3)
        defer { cleanup() }
        let work = space()
        let personal = space()

        try await host.load(installed, in: work)
        // The same bundle is not loaded in the other Space (per-Space, ADR 011).
        #expect(host.loadedExtensions(in: work).map(\.slug) == ["test-mv3"])
        #expect(host.loadedExtensions(in: personal).isEmpty)
    }

    @Test func anUnreadableBundleThrows() async throws {
        let host = WebKitExtensionHost()
        // A directory with no manifest.json is not a readable extension.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        await #expect(throws: ExtensionLoadError.self) {
            try await host.load(
                InstalledExtension(slug: "broken", resourceURL: dir), in: space()
            )
        }
    }
}
