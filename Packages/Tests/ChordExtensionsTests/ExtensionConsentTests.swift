import ChordCore
import Foundation
import Testing
import WebKit

@testable import ChordExtensions

/// Install consent (1mm.6.5): staging leaves nothing behind until committed,
/// the agreed grants are recorded, what an extension asks for reads plainly,
/// and an agreed install gets its manifest sites at load.
@Suite("Extension install consent")
@MainActor
struct ExtensionConsentTests {

    private func folder(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "chord-consent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, contents) in files {
            try contents.write(to: dir.appending(path: name), atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func zipData(_ folder: URL) throws -> Data {
        let out = FileManager.default.temporaryDirectory
            .appending(path: "chord-consent-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: out) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", out.path, "."]
        process.currentDirectoryURL = folder
        try process.run()
        process.waitUntilExit()
        return try Data(contentsOf: out)
    }

    private static let manifest = """
        { "manifest_version": 3, "name": "Tidy", "version": "1.0",
          "permissions": ["tabs", "storage", "history"],
          "host_permissions": ["https://example.com/*", "https://news.example.org/*"] }
        """

    @Test("A staged bundle discarded leaves the library empty")
    func discardLeavesNothing() throws {
        let source = try folder(["manifest.json": Self.manifest])
        defer { try? FileManager.default.removeItem(at: source) }
        let root = FileManager.default.temporaryDirectory.appending(path: "chord-lib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = ExtensionInstaller(extensionsDirectory: root)

        let staged = try installer.stage(data: zipData(source), sourceName: "tidy.zip")
        installer.discard(staged)

        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(try installer.installedExtensions().isEmpty)
    }

    @Test("Committing records what was agreed, and uninstalling forgets it")
    func commitRecordsConsent() throws {
        let source = try folder(["manifest.json": Self.manifest])
        defer { try? FileManager.default.removeItem(at: source) }
        let root = FileManager.default.temporaryDirectory.appending(path: "chord-lib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = ExtensionInstaller(extensionsDirectory: root)

        let staged = try installer.stage(data: zipData(source), sourceName: "tidy.zip")
        try installer.commit(staged, consented: ["tabs", "site:https://example.com/*"])

        let listed = try #require(try installer.installedExtensions().first)
        #expect(listed.consentedGrants == ["site:https://example.com/*", "tabs"])
        try installer.remove(slug: listed.slug)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test("Grants list permissions, sites and shim APIs, not what Chord added")
    func grantsListWhatItAsks() async throws {
        let dir = try folder(["manifest.json": Self.manifest])
        defer { try? FileManager.default.removeItem(at: dir) }
        try ExtensionShims.prepare(dir, fresh: true)

        let grants = await ExtensionConsent.grants(of: dir)

        #expect(grants.contains("tabs"))
        #expect(grants.contains("site:https://example.com/*"))
        #expect(grants.contains("chord:history"))
        // Chord adds nativeMessaging for its shim; the user didn't get asked
        // about that, so it isn't theirs to agree to.
        #expect(!grants.contains("nativeMessaging"))
    }

    @Test("The question says what it will be able to do, in words")
    func describeInWords() async throws {
        let dir = try folder(["manifest.json": Self.manifest])
        defer { try? FileManager.default.removeItem(at: dir) }
        try ExtensionShims.prepare(dir, fresh: true)

        let question = await ExtensionConsent.question(for: dir, name: "Tidy")

        #expect(question.wants.contains("Read and change what's on example.com, news.example.org"))
        #expect(question.wants.contains("See your open tabs and their addresses"))
        #expect(question.wants.contains("Read and change your history"))
        #expect(!question.wants.contains("Talk to apps on this Mac"))
    }

    @Test("Its manifest sites are granted as it loads, asked at install or added before")
    func consentedSitesAreGranted() async throws {
        let dir = try folder(["manifest.json": Self.manifest])
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = URL(string: "https://example.com/a")!
        let other = URL(string: "https://elsewhere.com/")!

        let agreed = WebKitExtensionHost()
        let space = Space(name: "W", sortIndex: 0)
        try await agreed.load(
            InstalledExtension(slug: "tidy", resourceURL: dir, consentedGrants: ["tabs"]), in: space
        )
        let context = try #require(agreed.context(forSlug: "tidy", in: space))
        #expect(context.permissionStatus(for: page) == .grantedExplicitly)
        #expect(context.permissionStatus(for: other) != .grantedExplicitly)

        let notAsked = WebKitExtensionHost()
        try await notAsked.load(InstalledExtension(slug: "tidy", resourceURL: dir), in: space)
        let legacy = try #require(notAsked.context(forSlug: "tidy", in: space))
        #expect(legacy.permissionStatus(for: page) == .grantedExplicitly)
        #expect(legacy.permissionStatus(for: other) != .grantedExplicitly)
    }
}
