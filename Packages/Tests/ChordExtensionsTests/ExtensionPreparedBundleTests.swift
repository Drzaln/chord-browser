import ChordCrypto
import Foundation
import Testing

@testable import ChordExtensions

/// M8: a verified bundle becomes a prepared directory with Chrome's identity
/// and the shim injected, while the signed ZIP stays beside it.
struct ExtensionPreparedBundleTests {
    private func makeSource(files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "chord-ext-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, contents) in files {
            let url = dir.appending(path: name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return dir
    }

    /// `ditto` reads the ZIP; `/usr/bin/zip` writes one without a dependency.
    private func zip(_ folder: URL, to destination: URL? = nil) throws -> URL {
        let out = destination ?? FileManager.default.temporaryDirectory
            .appending(path: "chord-ext-\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", out.path, "."]
        process.currentDirectoryURL = folder
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return out
    }

    private func makeInstaller() -> (ExtensionInstaller, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "chord-ext-lib-\(UUID().uuidString)")
        return (
            ExtensionInstaller(extensionsDirectory: root.appending(path: "Extensions")),
            root
        )
    }

    @Test func resolvesLocalisedManifestName() throws {
        let folder = try makeSource(files: [
            "manifest.json": """
                {
                  "manifest_version": 3,
                  "name": "__MSG_extName__",
                  "default_locale": "en",
                  "version": "1.0"
                }
                """,
            "_locales/en/messages.json": """
                { "extName": { "message": "Localised Test" } }
                """,
        ])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ExtensionBundle.displayName(at: folder) == "Localised Test")
        #expect(ExtensionBundle.displayName(at: folder) != "__MSG_extName__")

        // A key no locale defines is left as the manifest wrote it.
        let missing = try makeSource(files: [
            "manifest.json": """
                {
                  "manifest_version": 3,
                  "name": "__MSG_missing__",
                  "default_locale": "en",
                  "version": "1.0"
                }
                """,
        ])
        defer { try? FileManager.default.removeItem(at: missing) }
        #expect(ExtensionBundle.displayName(at: missing) == "__MSG_missing__")
    }

    private static let manifest = """
        {
          "manifest_version": 3,
          "name": "Prepared Test",
          "version": "1.2.3",
          "background": { "service_worker": "bg.js" },
          "content_scripts": [{ "matches": ["*://*/*"], "js": ["content.js"] }],
          "action": { "default_popup": "popup.html" },
          "permissions": ["storage"]
        }
        """

    @Test func installsAPreparedDirectoryAndKeepsTheZIP() throws {
        let source = try makeSource(files: [
            "manifest.json": Self.manifest,
            "bg.js": "globalThis.bg = true;\n",
            "content.js": "globalThis.content = true;\n",
            "popup.html": "<!doctype html><html><head></head><body>popup</body></html>",
        ])
        defer { try? FileManager.default.removeItem(at: source) }
        let zipURL = try zip(source)
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let (installer, root) = makeInstaller()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try installer.install(from: zipURL)

        #expect(installed.slug == zipURL.deletingPathExtension().lastPathComponent)
        #expect(ChromeExtensionID.isValid(installed.identifier))
        #expect(installed.version == "1.2.3")
        #expect(installed.resourceURL.pathExtension != "zip")
        #expect(FileManager.default.fileExists(
            atPath: installed.resourceURL.appending(path: "manifest.json").path
        ))

        // The signed ZIP remains, header-free, for provenance and re-prepare.
        let raw = installer.extensionsDirectory
            .appending(path: "\(installed.slug).zip")
        #expect(FileManager.default.fileExists(atPath: raw.path))
        #expect(FileManager.default.fileExists(
            atPath: installer.extensionsDirectory
                .appending(path: "\(installed.slug).identity").path
        ))

        let manifest = try ExtensionBundle.manifest(at: installed.resourceURL)
        let permissions = manifest["permissions"] as? [String] ?? []
        #expect(permissions.contains("nativeMessaging"))

        let background = try String(
            contentsOf: installed.resourceURL.appending(path: "bg.js"), encoding: .utf8
        )
        #expect(background.contains("Chord: Chrome APIs"))
        #expect(background.contains("define(\"offscreen\"") || background.contains("chrome.offscreen"))
        #expect(!background.contains("__SEARCH_SCRIPTS__"))
        #expect(!background.contains("__SEARCH_EVENTS__"))

        let content = try String(
            contentsOf: installed.resourceURL.appending(path: "content.js"), encoding: .utf8
        )
        #expect(content.contains("globalThis.content"))
        let scripts = manifest["content_scripts"] as? [[String: Any]]
        let js = scripts?.first?["js"] as? [String]
        #expect(js?.first == ExtensionShims.file)

        let popup = try String(
            contentsOf: installed.resourceURL.appending(path: "popup.html"), encoding: .utf8
        )
        #expect(popup.contains("chord-shim.js"))

        let listed = try installer.installedExtensions().first
        #expect(listed?.identifier == installed.identifier)
        #expect(listed?.displayName == "Prepared Test")
        #expect(listed?.version == "1.2.3")
        #expect(listed?.resourceURL == installed.resourceURL)
    }

    @Test func aStaleShimIsReappliedFromTheStoredZIP() throws {
        let source = try makeSource(files: [
            "manifest.json": Self.manifest,
            "bg.js": "globalThis.version = 1;\n",
            "popup.html": "<html><head></head><body>popup</body></html>",
        ])
        defer { try? FileManager.default.removeItem(at: source) }
        let zipURL = try zip(source)
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let (installer, root) = makeInstaller()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try installer.install(from: zipURL)
        let prepared = installed.resourceURL

        // A prepared tree stamped with an older shim must be rebuilt from the
        // stored ZIP, or a shim fix never reaches an existing install.
        try "0".write(
            to: prepared.appending(path: ExtensionShims.stamp), atomically: true, encoding: .utf8
        )
        try "globalThis.stale = true;\n".write(
            to: prepared.appending(path: "bg.js"), atomically: true, encoding: .utf8
        )

        let refreshed = installer.prepareIfNeeded(installed)
        #expect(refreshed.resourceURL == prepared)
        #expect(try String(
            contentsOf: refreshed.resourceURL.appending(path: ExtensionShims.stamp),
            encoding: .utf8
        ) == ExtensionShims.version)
        let background = try String(
            contentsOf: refreshed.resourceURL.appending(path: "bg.js"), encoding: .utf8
        )
        #expect(!background.contains("globalThis.stale"))
        #expect(background.contains(ExtensionShims.marker))
    }

    @Test func reinstallReplacesThePreparedTree() throws {
        let first = try makeSource(files: [
            "manifest.json": Self.manifest,
            "bg.js": "globalThis.version = 1;\n",
            "popup.html": "<html><head></head><body>one</body></html>",
        ])
        defer { try? FileManager.default.removeItem(at: first) }
        let firstZip = try zip(first)
        defer { try? FileManager.default.removeItem(at: firstZip) }

        let (installer, root) = makeInstaller()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try installer.install(from: firstZip)

        let second = try makeSource(files: [
            "manifest.json": Self.manifest.replacingOccurrences(
                of: "\"1.2.3\"", with: "\"1.2.4\""
            ),
            "bg.js": "globalThis.version = 2;\n",
            "popup.html": "<html><head></head><body>two</body></html>",
        ])
        defer { try? FileManager.default.removeItem(at: second) }
        let secondZip = try zip(second, to: firstZip)

        let replaced = try installer.install(from: secondZip)
        #expect(replaced.slug == installed.slug)
        #expect(replaced.version == "1.2.4")
        let background = try String(
            contentsOf: replaced.resourceURL.appending(path: "bg.js"), encoding: .utf8
        )
        #expect(background.contains("version = 2"))
        #expect(!background.contains("version = 1"))
    }

    @Test func preparesAnOlderZIPOnlyInstall() throws {
        let source = try makeSource(files: [
            "manifest.json": Self.manifest,
            "bg.js": "// bg\n",
            "popup.html": "<html><head></head><body></body></html>",
        ])
        defer { try? FileManager.default.removeItem(at: source) }
        let zipURL = try zip(source)
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let (installer, root) = makeInstaller()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try installer.install(from: zipURL)
        let raw = installer.extensionsDirectory.appending(path: "\(installed.slug).zip")
        try FileManager.default.removeItem(at: installed.resourceURL)
        try? FileManager.default.removeItem(
            at: installer.extensionsDirectory.appending(path: "\(installed.slug).identity")
        )

        let old = InstalledExtension(
            slug: installed.slug, resourceURL: raw, signatureStatus: .unsigned
        )
        let upgraded = installer.prepareIfNeeded(old)
        #expect(upgraded.resourceURL.pathExtension != "zip")
        #expect(ChromeExtensionID.isValid(upgraded.identifier))
        #expect(FileManager.default.fileExists(
            atPath: upgraded.resourceURL.appending(path: "manifest.json").path
        ))
    }

    @Test func removeDeletesPreparedZIPAndSidecars() throws {
        let source = try makeSource(files: [
            "manifest.json": Self.manifest,
            "bg.js": "// bg\n",
            "popup.html": "<html><head></head><body></body></html>",
        ])
        defer { try? FileManager.default.removeItem(at: source) }
        let zipURL = try zip(source)
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let (installer, root) = makeInstaller()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = try installer.install(from: zipURL)
        try installer.remove(slug: installed.slug)

        #expect(try installer.installedExtensions().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: installed.resourceURL.path))
        #expect(!FileManager.default.fileExists(
            atPath: installer.extensionsDirectory
                .appending(path: "\(installed.slug).zip").path
        ))
    }
}
