import AppKit
import ChordCore
import ChordEngine
import ChordExtensions
import Foundation
import Testing
import WebKit

@testable import ChordStore

@MainActor
private final class FakeHost: ExtensionHost {
    var loaded: [(slug: String, space: UUID)] = []
    var unloaded: [(slug: String, space: UUID)] = []
    var failSlugs: Set<String> = []
    /// "leftover" and "load:<slug>", in call order.
    var calls: [String] = []
    func forgetLeftOver(in spaces: [Space]) async { calls.append("leftover") }
    /// "<identifier>|<spaceID>" that set passwordSavingEnabled false.
    var turnedOffSaving: Set<String> = []
    func turnedOffPasswordSaving(identifier: String, in space: Space) -> Bool {
        turnedOffSaving.contains("\(identifier)|\(space.id)")
    }

    func load(_ installed: InstalledExtension, in space: Space) async throws -> LoadedExtension {
        calls.append("load:\(installed.slug)")
        if failSlugs.contains(installed.slug) {
            throw ExtensionLoadError.unsupportedManifestVersion(2)
        }
        loaded.append((installed.slug, space.id))
        return LoadedExtension(
            slug: installed.slug, spaceID: space.id, displayName: nil, manifestVersion: 3
        )
    }
    func unload(slug: String, in space: Space) throws { unloaded.append((slug, space.id)) }
    var forgotten: [(identifier: String, spaces: [UUID])] = []
    func forgetData(identifier: String, in spaces: [Space]) async {
        forgotten.append((identifier, spaces.map(\.id)))
    }
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
    func extensionTabDidMove(_ tabID: UUID, from oldIndex: Int, inSpace spaceID: UUID) {}
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
    /// `refusingPrivate` slugs get a prepared tree whose manifest says
    /// `"incognito": "not_allowed"`.
    private func makeService(installed slugs: [String], refusingPrivate: [String] = [])
        -> (ExtensionsService, FakeHost, FakeEnablement, cleanup: () -> Void)
    {
        let dir = FileManager.default.temporaryDirectory.appending(path: "extsvc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for slug in slugs {
            try? Data([0x50, 0x4B, 0x03, 0x04]).write(to: dir.appending(path: "\(slug).zip"))
        }
        for slug in refusingPrivate {
            let prepared = dir.appending(path: "\(slug).prepared")
            try? FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
            try? #"{ "manifest_version": 3, "name": "No", "version": "1", "incognito": "not_allowed" }"#
                .write(to: prepared.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
            try? ExtensionShims.stampValue(workerGeneration: 0)
                .write(to: prepared.appending(path: ExtensionShims.stamp), atomically: true, encoding: .utf8)
        }
        let host = FakeHost()
        let enablement = FakeEnablement()
        let service = ExtensionsService(
            installer: ExtensionInstaller(extensionsDirectory: dir),
            host: host, enablement: enablement, preferences: InMemoryPreferenceStore()
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

    @Test func passwordSavingIsTakenByTheExtensionThatTurnedItOff() async throws {
        let (service, host, _, cleanup) = makeService(installed: ["bitwarden", "ublock"])
        defer { cleanup() }
        let work = space()
        let home = space()
        try await service.enable(slug: "bitwarden", in: work)
        try await service.enable(slug: "ublock", in: work)
        try await service.enable(slug: "bitwarden", in: home)
        #expect(service.passwordSavingTakenBy(in: work) == nil)

        host.turnedOffSaving = ["bitwarden|\(work.id)"]
        #expect(service.passwordSavingTakenBy(in: work) == "bitwarden")
        #expect(service.passwordSavingTakenBy(in: home) == nil)
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

    @Test func removeForgetsWhatItKeptInPersistentSpaces() async throws {
        let (service, host, _, cleanup) = makeService(installed: ["bitwarden"])
        defer { cleanup() }
        let a = Space(name: "A", sortIndex: 0)
        let hidden = Space(name: "Private", sortIndex: 1, isPrivate: true)

        try await service.remove(slug: "bitwarden", from: [a, hidden])

        // Installed again, it must start from nothing, as in Chrome: Bitwarden
        // reinstalled over its old storage drew an empty popup. A private
        // Space keeps nothing past a quit, so there is nothing to clear there.
        #expect(host.forgotten.count == 1)
        #expect(host.forgotten.first?.identifier == "bitwarden")
        #expect(host.forgotten.first?.spaces == [a.id])
    }

    @Test func restoreLoadsEnabledExtensionsForExistingSpaces() async throws {
        let (service, host, enablement, cleanup) = makeService(installed: ["ublock", "dark"])
        defer { cleanup() }
        let s = space()
        try await enablement.setEnabled(true, slug: "ublock", spaceID: s.id)
        try await enablement.setEnabled(true, slug: "dark", spaceID: s.id)
        // An enabled record for a Space that no longer exists is skipped.
        try await enablement.setEnabled(true, slug: "ublock", spaceID: UUID())

        await service.restoreEnabled(spaces: [s], active: [s])
        #expect(host.loaded.map(\.slug).sorted() == ["dark", "ublock"])
        #expect(host.loaded.allSatisfy { $0.space == s.id })
    }

    @Test func restoreSkipsUninstalledSlugs() async throws {
        // Enabled record exists but the bundle is not on disk anymore.
        let (service, host, enablement, cleanup) = makeService(installed: [])
        defer { cleanup() }
        let s = space()
        try await enablement.setEnabled(true, slug: "gone", spaceID: s.id)

        await service.restoreEnabled(spaces: [s], active: [s])
        #expect(host.loaded.isEmpty)  // skipped, no crash
    }

    @Test func restoreLoadsOnlyTheSpacesOnScreen() async throws {
        let (service, host, enablement, cleanup) = makeService(installed: ["ublock", "dark"])
        defer { cleanup() }
        let a = space(), b = space(), c = space()
        for s in [a, b, c] {
            try await enablement.setEnabled(true, slug: "ublock", spaceID: s.id)
            try await enablement.setEnabled(true, slug: "dark", spaceID: s.id)
        }

        await service.restoreEnabled(spaces: [a, b, c], active: [a])

        #expect(host.loaded.count == 2)
        #expect(host.loaded.allSatisfy { $0.space == a.id })
    }

    @Test func firstShowOfASpaceLoadsItOnce() async throws {
        let (service, host, enablement, cleanup) = makeService(installed: ["ublock", "dark"])
        defer { cleanup() }
        let a = space(), b = space()
        for s in [a, b] {
            try await enablement.setEnabled(true, slug: "ublock", spaceID: s.id)
            try await enablement.setEnabled(true, slug: "dark", spaceID: s.id)
        }
        await service.restoreEnabled(spaces: [a, b], active: [a])

        await service.ensureLoaded(space: b)
        await service.ensureLoaded(space: b)
        await service.ensureLoaded(space: a)

        #expect(host.loaded.filter { $0.space == b.id }.map(\.slug).sorted() == ["dark", "ublock"])
        #expect(host.loaded.count == 4, "no Space loads twice")
    }

    @Test func extensionEnabledBeforeItsSpaceLoadsIsNotLoadedAgain() async throws {
        let (service, host, _, cleanup) = makeService(installed: ["ublock"])
        defer { cleanup() }
        let b = space()
        try await service.enable(slug: "ublock", in: b)

        await service.ensureLoaded(space: b)

        #expect(host.loaded.count == 1)
    }

    // MARK: - Private windows (Option A: off until allowed, per extension)

    private func privateSpace() -> Space { Space(name: "Private", sortIndex: 9, isPrivate: true) }

    @Test func aPrivateSpaceRunsNoExtensionByDefault() async throws {
        let (service, host, enablement, cleanup) = makeService(installed: ["ublock"])
        defer { cleanup() }
        try await enablement.setEnabled(true, slug: "ublock", spaceID: space().id)

        await service.ensureLoaded(space: privateSpace())

        #expect(host.loaded.isEmpty)
    }

    @Test func aPrivateSpaceRunsWhatWasAllowed() async throws {
        let (service, host, _, cleanup) = makeService(installed: ["ublock", "dark"])
        defer { cleanup() }
        let p = privateSpace()
        await service.setAllowedInPrivate(true, slug: "ublock", spaces: [])

        await service.ensureLoaded(space: p)

        #expect(host.loaded.map(\.slug) == ["ublock"])
        #expect(host.loaded.first?.space == p.id)
    }

    @Test func allowingLoadsIntoOpenPrivateSpacesAndDisallowingUnloads() async throws {
        let (service, host, _, cleanup) = makeService(installed: ["ublock"])
        defer { cleanup() }
        let p = privateSpace(), regular = space()
        await service.ensureLoaded(space: p)

        await service.setAllowedInPrivate(true, slug: "ublock", spaces: [regular, p])
        #expect(host.loaded.map(\.space) == [p.id], "only the private Space")

        await service.setAllowedInPrivate(false, slug: "ublock", spaces: [regular, p])
        #expect(host.unloaded.map(\.space) == [p.id])
        #expect(!service.isAllowedInPrivate(slug: "ublock"))
    }

    @Test func enablingInAPrivateWindowAllowsItAndKeepsNoRecord() async throws {
        let (service, host, enablement, cleanup) = makeService(installed: ["ublock"])
        defer { cleanup() }
        let p = privateSpace()
        await service.ensureLoaded(space: p)

        try await service.enable(slug: "ublock", in: p)
        #expect(service.isAllowedInPrivate(slug: "ublock"))
        #expect(host.loaded.map(\.space) == [p.id])
        #expect(try await enablement.allEnabled().isEmpty, "a private Space leaves nothing behind")

        try await service.disable(slug: "ublock", in: p)
        #expect(!service.isAllowedInPrivate(slug: "ublock"))
    }

    @Test func aManifestThatRefusesPrivateNeverLoadsThere() async throws {
        let (service, host, _, cleanup) = makeService(installed: ["nope"], refusingPrivate: ["nope"])
        defer { cleanup() }
        let p = privateSpace()
        await service.setAllowedInPrivate(true, slug: "nope", spaces: [])

        await service.ensureLoaded(space: p)
        #expect(host.loaded.isEmpty)
        await #expect(throws: ExtensionsServiceError.self) {
            try await service.enable(slug: "nope", in: p)
        }
    }

    @Test func launchFinishesLeftOverWipesBeforeAnythingLoads() async throws {
        let (service, host, enablement, cleanup) = makeService(installed: ["ublock"])
        defer { cleanup() }
        let s = space()
        try await enablement.setEnabled(true, slug: "ublock", spaceID: s.id)

        await service.restoreEnabled(spaces: [s], active: [s])

        #expect(host.calls == ["leftover", "load:ublock"])
    }

    // MARK: - Install consent (1mm.6.5)

    /// A real ZIP of a manifest, as a file, for `install(from:)`.
    private func bundle(_ manifest: String) throws -> URL {
        let src = FileManager.default.temporaryDirectory.appending(path: "svc-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: src) }
        try manifest.write(to: src.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        let out = FileManager.default.temporaryDirectory.appending(path: "tidy-\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", out.path, "."]
        process.currentDirectoryURL = src
        try process.run()
        process.waitUntilExit()
        return out
    }

    private static let tidy = """
        { "manifest_version": 3, "name": "Tidy", "version": "1.0",
          "permissions": ["storage"], "host_permissions": ["https://example.com/*"] }
        """
    private static let tidyWantsMore = """
        { "manifest_version": 3, "name": "Tidy", "version": "2.0",
          "permissions": ["storage", "tabs"], "host_permissions": ["https://example.com/*"] }
        """

    @Test func installAsksFirstAndRecordsWhatWasAgreed() async throws {
        let (service, _, _, cleanup) = makeService(installed: [])
        defer { cleanup() }
        let file = try bundle(Self.tidy)
        defer { try? FileManager.default.removeItem(at: file) }
        var asked: [ExtensionConsentQuestion] = []
        service.askToInstall = { asked.append($0); return true }

        let installed = try await service.install(from: file)

        #expect(asked.map(\.name) == ["Tidy"])
        #expect(asked.first?.updating == false)
        #expect(installed.consentedGrants?.contains("site:https://example.com/*") == true)
        #expect(try service.installedExtensions().count == 1)
    }

    @Test func cancellingTheInstallLeavesNothing() async throws {
        let (service, _, _, cleanup) = makeService(installed: [])
        defer { cleanup() }
        let file = try bundle(Self.tidy)
        defer { try? FileManager.default.removeItem(at: file) }
        service.askToInstall = { _ in false }

        await #expect(throws: ExtensionsServiceError.self) {
            try await service.install(from: file)
        }
        #expect(try service.installedExtensions().isEmpty)
    }

    @Test func anAgreedInstallIsNotAskedForSiteAccessOnEnable() async throws {
        let (service, host, _, cleanup) = makeService(installed: [])
        defer { cleanup() }
        let file = try bundle(Self.tidy)
        defer { try? FileManager.default.removeItem(at: file) }
        service.askToInstall = { _ in true }
        let installed = try await service.install(from: file)

        try await service.enable(slug: installed.slug, in: space())

        #expect(host.hostAccessPrompts.isEmpty, "the install question covered its sites")
    }

    @Test func anInstallNobodyWasAskedAboutStillAsksForSiteAccess() async throws {
        let (service, host, _, cleanup) = makeService(installed: ["legacy"])
        defer { cleanup() }

        try await service.enable(slug: "legacy", in: space())

        #expect(host.hostAccessPrompts.count == 1)
    }

    @Test func anUpdateAsksOnlyWhenItWantsMoreAndRefusalKeepsTheOldVersion() async throws {
        let (service, _, _, cleanup) = makeService(installed: [])
        defer { cleanup() }
        let first = try bundle(Self.tidy)
        defer { try? FileManager.default.removeItem(at: first) }
        var asked: [ExtensionConsentQuestion] = []
        var answer = true
        service.askToInstall = { asked.append($0); return answer }
        let installed = try await service.install(from: first)
        let installer = ExtensionInstaller(
            extensionsDirectory: installed.resourceURL.deletingLastPathComponent()
        )
        asked = []

        // The same asks: no question.
        let same = try installer.stage(
            data: Data(contentsOf: first), sourceName: "\(installed.slug).zip"
        )
        #expect(try await service.admitUpdate(same, replacing: installed) != nil)
        #expect(asked.isEmpty)

        // More: asked, as an update; no keeps 1.0.
        let moreFile = try bundle(Self.tidyWantsMore)
        defer { try? FileManager.default.removeItem(at: moreFile) }
        answer = false
        let more = try installer.stage(
            data: Data(contentsOf: moreFile), sourceName: "\(installed.slug).zip"
        )
        #expect(try await service.admitUpdate(more, replacing: installed) == nil)
        #expect(asked.map(\.updating) == [true])
        #expect(try service.installedExtensions().first?.version == "1.0")
    }
}
