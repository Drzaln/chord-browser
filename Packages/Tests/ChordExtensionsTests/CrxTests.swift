import ChordCrypto
import Foundation
import Testing

@testable import ChordExtensions

/// M9c: store URL/id parsing and the store-install marker.
struct CrxTests {
    private let id = String(repeating: "a", count: 32)

    @Test func idIsFoundInAStoreLinkOrBare() {
        #expect(Crx.id(in: "https://chromewebstore.google.com/detail/name/\(id)") == id)
        #expect(Crx.id(in: id) == id)
        #expect(Crx.id(in: "https://example.com/nope") == nil)
    }

    @Test func storeIDOnlyComesFromTheStorePath() {
        #expect(Crx.storeID(of: URL(string:
            "https://chromewebstore.google.com/detail/name/\(id)")!) == id)
        #expect(Crx.storeID(of: URL(string:
            "https://chrome.google.com/webstore/detail/name/\(id)")!) == id)
        #expect(Crx.storeID(of: URL(string:
            "https://example.com/detail/\(id)")!) == nil)
    }

    @Test func downloadURLNamesTheExtensionAndChromeVersion() {
        let url = Crx.downloadURL(for: id)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []
        #expect(query.first { $0.name == "prodversion" }?.value == "156.0.0.0")
        #expect(query.first { $0.name == "acceptformat" }?.value == "crx3")
        #expect(query.first { $0.name == "x" }?.value?.contains("id=\(id)") == true)
    }

    @Test func storeInstallsAreMarkedForUpdates() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "chord-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = ExtensionInstaller(
            extensionsDirectory: root.appending(path: "Extensions")
        )
        let zip = Data([0x50, 0x4B, 0x03, 0x04] + Array(0..<64))
        let installed = try installer.install(
            data: zip, sourceName: "\(id).crx", fromStore: true
        )
        #expect(installed.slug == id)
        #expect(installed.fromStore)
        #expect(try installer.installedExtensions().first?.fromStore == true)
    }
}
