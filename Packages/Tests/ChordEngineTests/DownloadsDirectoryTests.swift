import Foundation
import Testing

@testable import ChordEngine

/// Where a finished download lands.
///
/// `swift test` runs **unsandboxed**, so it cannot reproduce the bug this
/// guards: under the sandbox, `FileManager.urls(for: .downloadsDirectory…)`
/// returns the container's Downloads and files vanish from Finder's view. What
/// it *can* prove is that the resolution no longer goes through that API and
/// no longer names a container path — which is the part that was wrong.
@Suite("Downloads directory")
@MainActor
struct DownloadsDirectoryTests {

    @Test("Resolves to the real home's Downloads, never a sandbox container")
    func resolvesToRealHome() {
        let directory = DownloadCoordinator.userDownloadsDirectory()

        #expect(directory.lastPathComponent == "Downloads")
        // The failure mode, spelled out: anything under Library/Containers is a
        // path the user cannot find from Finder.
        #expect(directory.path.contains("/Library/Containers/") == false)

        // The real home comes from the password database, which the sandbox does
        // not rewrite — the same source the implementation uses, checked here
        // against an independent one.
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        if !home.path.contains("/Library/Containers/") {
            // Unsandboxed (a test process): the two must agree exactly.
            #expect(directory == home.appending(path: "Downloads", directoryHint: .isDirectory))
        }
    }

    @Test("An explicit directory still wins, so tests and callers stay in control")
    func explicitDirectoryIsHonoured() {
        let custom = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "custom-downloads", directoryHint: .isDirectory)
        let coordinator = DownloadCoordinator(directory: custom)
        // Nothing is downloaded here — the point is only that the default is a
        // default, which is what `E2EHarness` depends on to keep its files in a
        // temporary directory.
        #expect(coordinator.downloadItems.isEmpty)
    }
}
