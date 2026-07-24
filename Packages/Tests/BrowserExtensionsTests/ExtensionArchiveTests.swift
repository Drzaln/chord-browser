import Foundation
import Testing

@testable import BrowserExtensions

/// M7 phase 7.2: turning a `.crx`/`.xpi` into a ZIP `WKWebExtension` can read.
struct ExtensionArchiveTests {
    // A stand-in ZIP: the local-file-header magic plus arbitrary bytes. 7.2
    // never parses inside the ZIP, so its magic is all that must be real.
    private static let fakeZIP = Data([0x50, 0x4B, 0x03, 0x04] + Array(0..<40))

    private static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }

    private static func crx3(headerSize: Int, zip: Data = fakeZIP) -> Data {
        var d = Data("Cr24".utf8)
        d += le32(3)
        d += le32(UInt32(headerSize))
        d += Data(repeating: 0xAB, count: headerSize)
        d += zip
        return d
    }

    private static func crx2(pubKeyLen: Int, sigLen: Int, zip: Data = fakeZIP) -> Data {
        var d = Data("Cr24".utf8)
        d += le32(2)
        d += le32(UInt32(pubKeyLen))
        d += le32(UInt32(sigLen))
        d += Data(repeating: 0xCD, count: pubKeyLen)
        d += Data(repeating: 0xEF, count: sigLen)
        d += zip
        return d
    }

    // MARK: - Detection

    @Test func detectsZIPandCRXandRejectsOther() {
        #expect(ExtensionArchive.detectFormat(Self.fakeZIP) == .zip)
        #expect(ExtensionArchive.detectFormat(Self.crx3(headerSize: 8)) == .crx)
        #expect(ExtensionArchive.detectFormat(Data([0x00, 0x01, 0x02, 0x03])) == nil)
    }

    // MARK: - Payload recovery

    @Test func zipPassesThroughUnchanged() throws {
        #expect(try ExtensionArchive.zipPayload(from: Self.fakeZIP) == Self.fakeZIP)
    }

    @Test func crx3HeaderIsStripped() throws {
        let recovered = try ExtensionArchive.zipPayload(from: Self.crx3(headerSize: 137))
        #expect(recovered == Self.fakeZIP)
    }

    @Test func crx2HeaderIsStripped() throws {
        let recovered = try ExtensionArchive.zipPayload(from: Self.crx2(pubKeyLen: 91, sigLen: 256))
        #expect(recovered == Self.fakeZIP)
    }

    @Test func unrecognisedFormatThrows() {
        #expect(throws: ExtensionArchiveError.unrecognizedFormat) {
            try ExtensionArchive.zipPayload(from: Data([0, 1, 2, 3, 4, 5]))
        }
    }

    @Test func unsupportedCRXVersionThrows() {
        var d = Data("Cr24".utf8)
        d += Self.le32(4)  // no such CRX version
        d += Self.le32(0)
        #expect(throws: ExtensionArchiveError.unsupportedCRXVersion(4)) {
            try ExtensionArchive.zipPayload(from: d)
        }
    }

    @Test func truncatedCRXHeaderThrows() {
        // Claims a 999-byte header but carries far fewer bytes.
        var d = Data("Cr24".utf8)
        d += Self.le32(3)
        d += Self.le32(999)
        d += Data([0x00, 0x01])
        #expect(throws: ExtensionArchiveError.truncatedCRXHeader) {
            try ExtensionArchive.zipPayload(from: d)
        }
    }

    @Test func crxWhosePayloadIsNotZIPThrows() {
        var d = Data("Cr24".utf8)
        d += Self.le32(3)
        d += Self.le32(4)
        d += Data(repeating: 0xAB, count: 4)
        d += Data([0x11, 0x22, 0x33, 0x44])  // not "PK\x03\x04"
        #expect(throws: ExtensionArchiveError.crxPayloadNotZIP) {
            try ExtensionArchive.zipPayload(from: d)
        }
    }
}

/// The on-disk library: install, list, remove.
struct ExtensionInstallerTests {
    private static let fakeZIP = Data([0x50, 0x4B, 0x03, 0x04] + Array(0..<40))

    /// A fresh temp directory per call; the returned installer points at a
    /// not-yet-created `Extensions/` under it so `install` must create it.
    private func makeInstaller() throws -> (ExtensionInstaller, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "extinstaller-\(UUID().uuidString)")
        let installer = ExtensionInstaller(extensionsDirectory: root.appending(path: "Extensions"))
        return (installer, { try? FileManager.default.removeItem(at: root) })
    }

    private func writeTemp(_ data: Data, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try data.write(to: url)
        return url
    }

    @Test func installsXPIAsIsAndListsIt() throws {
        let (installer, cleanup) = try makeInstaller()
        defer { cleanup() }

        let source = try writeTemp(Self.fakeZIP, name: "uBlock.xpi")
        let installed = try installer.install(from: source)

        #expect(installed.slug == "uBlock")
        #expect(FileManager.default.fileExists(atPath: installed.resourceURL.path))
        #expect(try Data(contentsOf: installed.resourceURL) == Self.fakeZIP)
        // Compare by slug, not by URL: `contentsOfDirectory` resolves the
        // temp-dir /var→/private/var symlink and so spells the same path
        // differently than `install` returned.
        #expect(try installer.installedExtensions().map(\.slug) == ["uBlock"])
    }

    @Test func installsCRXByStrippingItsHeader() throws {
        let (installer, cleanup) = try makeInstaller()
        defer { cleanup() }

        var crx = Data("Cr24".utf8)
        crx += Data([0x03, 0, 0, 0])  // version 3
        crx += Data([0x04, 0, 0, 0])  // header size 4
        crx += Data(repeating: 0xAB, count: 4)
        crx += Self.fakeZIP
        let source = try writeTemp(crx, name: "darkreader.crx")

        let installed = try installer.install(from: source)
        // What lands on disk is the ZIP WebKit can read, header gone.
        #expect(try Data(contentsOf: installed.resourceURL) == Self.fakeZIP)
    }

    @Test func reinstallOverwritesInPlace() throws {
        let (installer, cleanup) = try makeInstaller()
        defer { cleanup() }

        let first = try writeTemp(Self.fakeZIP, name: "ext.xpi")
        _ = try installer.install(from: first)

        let newBytes = Data([0x50, 0x4B, 0x03, 0x04] + Array(50..<70))
        let second = try writeTemp(newBytes, name: "ext.xpi")
        let installed = try installer.install(from: second)

        #expect(try installer.installedExtensions().count == 1)
        #expect(try Data(contentsOf: installed.resourceURL) == newBytes)
    }

    @Test func removeDeletesTheBundle() throws {
        let (installer, cleanup) = try makeInstaller()
        defer { cleanup() }

        let source = try writeTemp(Self.fakeZIP, name: "ext.xpi")
        let installed = try installer.install(from: source)
        try installer.remove(slug: installed.slug)

        #expect(try installer.installedExtensions().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: installed.resourceURL.path))
    }

    @Test func listingIsEmptyWhenDirectoryDoesNotExist() throws {
        let (installer, cleanup) = try makeInstaller()
        defer { cleanup() }
        #expect(try installer.installedExtensions().isEmpty)
    }

    @Test func hostileFilenameCannotEscapeTheDirectory() throws {
        // A source name full of path separators and dots must collapse to a
        // slug that stays inside Extensions/.
        let slug = ExtensionInstaller.slug(
            for: URL(fileURLWithPath: "/tmp/..%2F..%2Fetc%2Fpasswd.crx")
        )
        #expect(!slug.contains("/"))
        #expect(!slug.contains(".."))
        #expect(!slug.isEmpty)
    }
}
