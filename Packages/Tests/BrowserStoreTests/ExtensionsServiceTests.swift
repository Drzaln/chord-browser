import AppKit
import BrowserCore
import BrowserEngine
import BrowserExtensions
import Foundation
import Testing
import WebKit

@testable import BrowserStore

@MainActor
private final class FakeHost: ExtensionHost {
    var loaded: [(slug: String, space: UUID)] = []
    var unloaded: [(slug: String, space: UUID)] = []
    var failSlugs: Set<String> = []

    func load(_ installed: InstalledExtension, in space: Space) async throws -> LoadedExtension {
        if failSlugs.contains(installed.slug) {
            throw ExtensionLoadError.unsupportedManifestVersion(2)
        }
        loaded.append((installed.slug, space.id))
        return LoadedExtension(
            slug: installed.slug, spaceID: space.id, displayName: nil, manifestVersion: 3
        )
    }
    func unload(slug: String, in space: Space) throws { unloaded.append((slug, space.id)) }
    func loadedExtensions(in space: Space) -> [LoadedExtension] {
        loaded.filter { $0.space == space.id }.map {
            LoadedExtension(slug: $0.slug, spaceID: space.id, displayName: nil, manifestVersion: 3)
        }
    }
    // Unused here.
    var preparedSpaceIDs: Set<UUID> { [] }
    func prepare(_ space: Space) -> ExtensionControllerHandle {
        ExtensionControllerHandle(WKWebExtensionController())
    }
    func extensionControllerHandle(for space: Space) -> ExtensionControllerHandle? { nil }
    func extensionTabDidOpen(_ tabID: UUID, inSpace spaceID: UUID) {}
    func extensionTabDidActivate(_ tabID: UUID, previous: UUID?, inSpace spaceID: UUID) {}
    func extensionTabDidClose(_ tabID: UUID, inSpace spaceID: UUID) {}
    func actions(in space: Space) -> [ExtensionActionSnapshot] { [] }
    var onActionsChanged: (@MainActor () -> Void)?
    var onPopupVisibilityChanged: (@MainActor (AnyObject?, Bool) -> Void)?
    func registerActionAnchor(_ view: NSView?, forSlug slug: String, in space: Space) {}
    func presentAction(slug: String, in space: Space) {}
    var onPermissionRequest: (@MainActor (PermissionRequest) -> Void)?
    func resolvePermission(id: UUID, allow: Bool) {}
    func hasAllHostsAccess(slug: String, in space: Space) -> Bool { false }
    func setAllHostsAccess(_ granted: Bool, slug: String, in space: Space) {}
    var onHostAccessChanged: (@MainActor (UUID) -> Void)?
    private(set) var hostAccessPrompts: [(slug: String, space: UUID)] = []
    func promptForHostAccess(slug: String, in space: Space) {
        hostAccessPrompts.append((slug, space.id))
    }
}

private actor FakeEnablement: ExtensionEnablementRepository {
    private var records: Set<ExtensionEnablementRecord> = []
    func allEnabled() async throws -> [ExtensionEnablementRecord] { Array(records) }
    func enabledSlugs(spaceID: UUID) async throws -> [String] {
        records.filter { $0.spaceID == spaceID }.map(\.slug)
    }
    func setEnabled(_ enabled: Bool, slug: String, spaceID: UUID) async throws {
        let record = ExtensionEnablementRecord(spaceID: spaceID, slug: slug)
        if enabled { records.insert(record) } else { records.remove(record) }
    }
}

@MainActor
struct ExtensionsServiceTests {
    /// A temp Extensions dir seeded with a dummy `.zip` per slug, so the real
    /// installer lists them. The fake host never reads the file.
    private func makeService(installed slugs: [String])
        -> (ExtensionsService, FakeHost, FakeEnablement, cleanup: () -> Void)
    {
        let dir = FileManager.default.temporaryDirectory.appending(path: "extsvc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for slug in slugs {
            try? Data([0x50, 0x4B, 0x03, 0x04]).write(to: dir.appending(path: "\(slug).zip"))
        }
        let host = FakeHost()
        let enablement = FakeEnablement()
        let service = ExtensionsService(
            installer: ExtensionInstaller(extensionsDirectory: dir),
            host: host, enablement: enablement
        )
        return (service, host, enablement, { try? FileManager.default.removeItem(at: dir) })
    }

    private func space() -> Space { Space(name: "Work", sortIndex: 0) }

    @Test func enableLoadsAndPersists() async throws {
        let (service, host, enablement, cleanup) = makeService(installed: ["ublock"])
        defer { cleanup() }
        let s = space()

        try await service.enable(slug: "ublock", in: s)
        #expect(host.loaded.map(\.slug) == ["ublock"])
        #expect(try await enablement.enabledSlugs(spaceID: s.id) == ["ublock"])
    }

    @Test func enableOfUnknownThrowsAndDoesNotPersist() async throws {
        let (service, host, enablement, cleanup) = makeService(installed: [])
        defer { cleanup() }
        let s = space()

        await #expect(throws: ExtensionsServiceError.self) {
            try await service.enable(slug: "ghost", in: s)
        }
        #expect(host.loaded.isEmpty)
        #expect(try await enablement.allEnabled().isEmpty)
    }

    @Test func failedLoadDoesNotMarkEnabled() async throws {
        let (service, host, enablement, cleanup) = makeService(installed: ["bad"])
        defer { cleanup() }
        host.failSlugs = ["bad"]
        let s = space()

        await #expect(throws: (any Error).self) { try await service.enable(slug: "bad", in: s) }
        // Persist only happens after a successful load.
        #expect(try await enablement.allEnabled().isEmpty)
    }

    @Test func disableUnloadsAndPersists() async throws {
        let (service, host, enablement, cleanup) = makeService(installed: ["ublock"])
        defer { cleanup() }
        let s = space()
        try await service.enable(slug: "ublock", in: s)

        try await service.disable(slug: "ublock", in: s)
        #expect(host.unloaded.map(\.slug) == ["ublock"])
        #expect(try await enablement.enabledSlugs(spaceID: s.id).isEmpty)
    }

    @Test func enablePromptsForHostAccess() async throws {
        let (service, host, _, cleanup) = makeService(installed: ["ublock"])
        defer { cleanup() }
        let s = space()

        try await service.enable(slug: "ublock", in: s)

        // Enable prompts for host access (WebKit does not auto-prompt); restore
        // must not (it re-applies persisted grants silently).
        #expect(host.hostAccessPrompts.map(\.slug) == ["ublock"])
    }

    @Test func removeUnloadsFromAllSpacesAndDeletesFromDisk() async throws {
        let (service, host, enablement, cleanup) = makeService(installed: ["ublock"])
        defer { cleanup() }
        let a = Space(name: "A", sortIndex: 0)
        let b = Space(name: "B", sortIndex: 1)
        try await service.enable(slug: "ublock", in: a)
        try await service.enable(slug: "ublock", in: b)

        try await service.remove(slug: "ublock", from: [a, b])

        // Unloaded from both Spaces, unmarked everywhere, and gone from the library.
        #expect(Set(host.unloaded.map(\.space)) == [a.id, b.id])
        #expect(try await enablement.allEnabled().isEmpty)
        #expect(try service.installedExtensions().isEmpty)
    }

    @Test func restoreLoadsEnabledExtensionsForExistingSpaces() async throws {
        let (service, host, enablement, cleanup) = makeService(installed: ["ublock", "dark"])
        defer { cleanup() }
        let s = space()
        try await enablement.setEnabled(true, slug: "ublock", spaceID: s.id)
        try await enablement.setEnabled(true, slug: "dark", spaceID: s.id)
        // An enabled record for a Space that no longer exists is skipped.
        try await enablement.setEnabled(true, slug: "ublock", spaceID: UUID())

        await service.restoreEnabled(spaces: [s])
        #expect(host.loaded.map(\.slug).sorted() == ["dark", "ublock"])
        #expect(host.loaded.allSatisfy { $0.space == s.id })
    }

    @Test func restoreSkipsUninstalledSlugs() async throws {
        // Enabled record exists but the bundle is not on disk anymore.
        let (service, host, enablement, cleanup) = makeService(installed: [])
        defer { cleanup() }
        let s = space()
        try await enablement.setEnabled(true, slug: "gone", spaceID: s.id)

        await service.restoreEnabled(spaces: [s])
        #expect(host.loaded.isEmpty)  // skipped, no crash
    }
}
