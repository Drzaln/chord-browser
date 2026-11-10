import Foundation
import Testing

@testable import ChordUpdater

/// The install half of an update, against real bundles signed ad hoc with the
/// system's own `codesign`. No network: the tests start from a zip on disk.
@Suite("App installer")
struct AppInstallerTests {
    private static let bundleID = "com.example.chord-test"

    /// A scratch root holding `Applications/`, `Updates/` and the build area.
    private final class Scratch {
        let root: URL
        var applications: URL { root.appendingPathComponent("Applications", isDirectory: true) }
        var updates: URL { root.appendingPathComponent("Updates", isDirectory: true) }
        var build: URL { root.appendingPathComponent("build", isDirectory: true) }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("chord-installer-\(UUID().uuidString)", isDirectory: true)
            for directory in [applications, updates, build] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(tool) \(arguments)")
    }

    /// Builds `Chord.app` under `directory` with a real Mach-O inside.
    private func makeApp(
        in directory: URL, bundleID: String = AppInstallerTests.bundleID,
        version: String = "2.0.0", marker: String = "new", signed: Bool = true
    ) throws -> URL {
        let app = directory.appendingPathComponent("Chord.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try fileManager.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: contents.appendingPathComponent("MacOS/Chord"))
        try Data(marker.utf8).write(to: contents.appendingPathComponent("Resources/marker.txt"))
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "Chord",
            "CFBundleShortVersionString": version,
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        if signed { try run("/usr/bin/codesign", ["-f", "-s", "-", app.path]) }
        return app
    }

    private func zip(_ app: URL, in scratch: Scratch) throws -> URL {
        let archive = scratch.build.appendingPathComponent("Chord.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path])
        return archive
    }

    private func release(_ tag: String = "v2.0.0") -> GitHubRelease {
        GitHubRelease(
            tagName: tag, name: tag, htmlURL: URL(string: "https://example.com")!,
            isPrerelease: false, publishedAt: nil, assets: [])
    }

    private func installer(_ scratch: Scratch, teamID: String? = nil) -> AppInstaller {
        AppInstaller(
            applicationsDirectory: scratch.applications,
            supportDirectory: scratch.updates,
            expected: BundleIdentity(bundleID: Self.bundleID, teamID: teamID))
    }

    private func marker(of app: URL) -> String? {
        try? String(
            contentsOf: app.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8)
    }

    /// Puts an "old" copy where the installed app lives and returns its URL.
    private func installOld(in scratch: Scratch) throws -> URL {
        try makeApp(in: scratch.applications, version: "1.0.0", marker: "old")
    }

    private func staging(_ scratch: Scratch) throws -> URL {
        let staging = scratch.updates.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    @Test("A signed bundle with the right identifier and version replaces the installed app")
    func installs() throws {
        let scratch = try Scratch()
        let old = try installOld(in: scratch)
        let archive = try zip(try makeApp(in: scratch.build), in: scratch)

        let installed = try installer(scratch).installDownloaded(
            zip: archive, release: release(), staging: try staging(scratch))

        #expect(installed.path == old.path)
        #expect(marker(of: installed) == "new")
        // Nothing of the old copy is left beside it.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratch.applications.path)
        #expect(leftovers == ["Chord.app"])
    }

    @Test("A bundle with another identifier is refused and the installed app is untouched")
    func refusesAnotherApp() throws {
        let scratch = try Scratch()
        let old = try installOld(in: scratch)
        let archive = try zip(try makeApp(in: scratch.build, bundleID: "com.example.other"), in: scratch)

        #expect(throws: AppInstaller.InstallError.self) {
            try installer(scratch).installDownloaded(
                zip: archive, release: release(), staging: try staging(scratch))
        }
        #expect(marker(of: old) == "old")
    }

    @Test("A bundle whose version is not the release's is refused")
    func refusesAnotherVersion() throws {
        let scratch = try Scratch()
        let old = try installOld(in: scratch)
        let archive = try zip(try makeApp(in: scratch.build, version: "1.5.0"), in: scratch)

        #expect(throws: AppInstaller.InstallError.self) {
            try installer(scratch).installDownloaded(
                zip: archive, release: release(), staging: try staging(scratch))
        }
        #expect(marker(of: old) == "old")
    }

    @Test("A bundle changed after it was signed is refused")
    func refusesTampered() throws {
        let scratch = try Scratch()
        let old = try installOld(in: scratch)
        let app = try makeApp(in: scratch.build)
        try Data("changed".utf8).write(to: app.appendingPathComponent("Contents/Resources/marker.txt"))
        let archive = try zip(app, in: scratch)

        #expect(throws: AppInstaller.InstallError.self) {
            try installer(scratch).installDownloaded(
                zip: archive, release: release(), staging: try staging(scratch))
        }
        #expect(marker(of: old) == "old")
    }

    @Test("An unsigned bundle is refused")
    func refusesUnsigned() throws {
        let scratch = try Scratch()
        let old = try installOld(in: scratch)
        let archive = try zip(try makeApp(in: scratch.build, signed: false), in: scratch)

        #expect(throws: AppInstaller.InstallError.self) {
            try installer(scratch).installDownloaded(
                zip: archive, release: release(), staging: try staging(scratch))
        }
        #expect(marker(of: old) == "old")
    }

    @Test("When the running app is signed by a team, a bundle from no team is refused")
    func refusesAnotherTeam() throws {
        let scratch = try Scratch()
        let old = try installOld(in: scratch)
        let archive = try zip(try makeApp(in: scratch.build), in: scratch)

        #expect(throws: AppInstaller.InstallError.self) {
            try installer(scratch, teamID: "ABCDE12345").installDownloaded(
                zip: archive, release: release(), staging: try staging(scratch))
        }
        #expect(marker(of: old) == "old")
    }

    @Test("A swap that fails puts the installed app back")
    func failedSwapRestores() throws {
        let scratch = try Scratch()
        let old = try installOld(in: scratch)
        let missing = scratch.build.appendingPathComponent("Nowhere.app")

        #expect(throws: (any Error).self) {
            try installer(scratch).swap(intoPlace: old, from: missing)
        }
        #expect(marker(of: old) == "old")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratch.applications.path)
        #expect(leftovers == ["Chord.app"])
    }
}
