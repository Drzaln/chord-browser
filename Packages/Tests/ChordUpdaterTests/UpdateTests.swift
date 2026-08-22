import Testing
import Foundation
@testable import ChordUpdater

struct VersionTests {
    @Test func parsesPlainVersion() throws {
        let v = try #require(Version(raw: "1.2.0"))
        #expect(v.major == 1 && v.minor == 2 && v.patch == 0)
        #expect(v.prerelease == nil)
        #expect(v.description == "1.2.0")
    }

    @Test func parsesVPrefixedTag() throws {
        let v = try #require(Version(raw: "v1.2.0"))
        #expect(v.description == "1.2.0")
    }

    @Test func parsesShortVersion() throws {
        let v = try #require(Version(raw: "1.2"))
        #expect(v.major == 1 && v.minor == 2 && v.patch == 0)
    }

    @Test func parsesPrerelease() throws {
        let v = try #require(Version(raw: "1.3.0-beta.1"))
        #expect(v.prerelease == ["beta", "1"])
        #expect(v.description == "1.3.0-beta.1")
    }

    @Test func rejectsGarbage() {
        #expect(Version(raw: "banana") == nil)
        #expect(Version(raw: "") == nil)
    }

    @Test func ordersReleases() {
        #expect(Version(raw: "1.2.0")! < Version(raw: "1.3.0")!)
        #expect(Version(raw: "1.2.9")! < Version(raw: "1.3.0")!)
        #expect(Version(raw: "1.3.0")! < Version(raw: "2.0.0")!)
        #expect(Version(raw: "1.3.0")! == Version(raw: "v1.3.0")!)
        #expect(!(Version(raw: "1.3.0")! < Version(raw: "1.3.0")!))
    }

    @Test func ordersPrereleasesBelowReleases() {
        #expect(Version(raw: "1.3.0-beta.1")! < Version(raw: "1.3.0")!)
        #expect(Version(raw: "1.3.0-beta.1")! < Version(raw: "1.3.0-beta.2")!)
        #expect(Version(raw: "1.3.0-beta")! < Version(raw: "1.3.0")!)
    }

    @Test func updateJudgement() {
        let local = Version(raw: "1.2.0")!
        // Local 1.2.0 == latest 1.2.0 → up to date.
        #expect(!(Version(raw: "v1.2.0")! > local))
        // Local 1.2.0 < 1.2.1 → update.
        #expect(Version(raw: "1.2.1")! > local)
    }
}

struct GitHubReleaseTests {
    private let fixture = """
    {
      "url": "https://api.github.com/repos/Drzaln/chord-browser/releases/1",
      "tag_name": "v1.2.0",
      "name": "v1.2.0",
      "draft": false,
      "prerelease": false,
      "html_url": "https://github.com/Drzaln/chord-browser/releases/tag/v1.2.0",
      "published_at": "2026-08-21T14:44:52Z",
      "assets": [
        {
          "name": "Chord.zip",
          "browser_download_url": "https://github.com/Drzaln/chord-browser/releases/download/v1.2.0/Chord.zip",
          "size": 5409746,
          "content_type": "application/zip"
        }
      ]
    }
    """

    @Test func decodesRelease() throws {
        let data = Data(fixture.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(GitHubRelease.self, from: data)

        #expect(release.tagName == "v1.2.0")
        #expect(release.version == Version(raw: "1.2.0"))
        #expect(!release.isPrerelease)
        #expect(release.publishedAt != nil)
        #expect(release.assets.count == 1)
    }

    @Test func findsZipAsset() throws {
        let data = Data(fixture.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(GitHubRelease.self, from: data)

        let zip = try #require(release.zipAsset)
        #expect(zip.name == "Chord.zip")
        #expect(zip.downloadURL.absoluteString.hasSuffix("Chord.zip"))
    }

    @Test func missingAssetsYieldsNoZip() throws {
        let data = Data(#"{"tag_name":"v1.0.0","assets":[]}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(GitHubRelease.self, from: data)
        #expect(release.zipAsset == nil)
    }
}

struct GitHubReleaseCheckingTests {
    @Test func parsesTagFromLatestRedirect() {
        #expect(
            GitHubReleaseChecking.parseTag(
                from: "https://github.com/Drzaln/chord-browser/releases/tag/v1.4.4"
            ) == "v1.4.4"
        )
    }

    @Test func parsesTagFromRedirectWithSlashInTag() {
        #expect(
            GitHubReleaseChecking.parseTag(
                from: "https://github.com/Drzaln/chord-browser/releases/tag/release/candidate-2"
            ) == "release/candidate-2"
        )
    }

    @Test func parseTagHandlesBarePath() {
        #expect(GitHubReleaseChecking.parseTag(from: "/Drzaln/chord-browser/releases/tag/v1.0.0") == "v1.0.0")
        #expect(GitHubReleaseChecking.parseTag(from: "") == nil)
    }
}

struct UpdateControllerTests {
    /// A fake release checker so the controller's branching is tested without
    /// the network.
    private struct StubChecker: ReleaseChecking {
        let result: Result<GitHubRelease?, any Error>
        func latestRelease() async throws -> GitHubRelease? {
            try result.get()
        }
    }

    private func release(_ tag: String) -> GitHubRelease {
        GitHubRelease(
            tagName: tag, name: tag,
            htmlURL: URL(string: "https://github.com/Drzaln/chord-browser/releases/tag/\(tag)")!,
            isPrerelease: false, publishedAt: nil,
            assets: [
                .init(
                    name: "Chord.zip",
                    downloadURL: URL(string: "https://example.com/Chord.zip")!,
                    sizeBytes: 1, contentType: "application/zip"
                )
            ]
        )
    }

    @MainActor
    @Test func upToDateWhenLocalNotBehind() async {
        let controller = UpdateController(
            currentVersion: Version(raw: "1.3.0")!,
            releaseChecker: StubChecker(result: .success(release("v1.2.0")))
        )
        await controller.checkForUpdates()
        #expect(controller.phase == .upToDate)
    }

    @MainActor
    @Test func updateWhenReleaseIsNewer() async {
        let controller = UpdateController(
            currentVersion: Version(raw: "1.2.0")!,
            releaseChecker: StubChecker(result: .success(release("v1.2.1")))
        )
        await controller.checkForUpdates()
        #expect(controller.hasUpdate)
    }

    @MainActor
    @Test func ignoresPrerelease() async {
        let prerelease = GitHubRelease(
            tagName: "v1.2.1", name: "v1.2.1",
            htmlURL: URL(string: "https://github.com/Drzaln/chord-browser/releases/tag/v1.2.1")!,
            isPrerelease: true, publishedAt: nil, assets: []
        )
        let controller = UpdateController(
            currentVersion: Version(raw: "1.2.0")!,
            releaseChecker: StubChecker(result: .success(prerelease))
        )
        await controller.checkForUpdates()
        #expect(controller.phase == .upToDate)
    }

    @MainActor
    @Test func noReleaseMeansUpToDate() async {
        let controller = UpdateController(
            currentVersion: Version(raw: "1.2.0")!,
            releaseChecker: StubChecker(result: .success(nil))
        )
        await controller.checkForUpdates()
        #expect(controller.phase == .upToDate)
    }

    @MainActor
    @Test func surfacesCheckFailure() async {
        let controller = UpdateController(
            currentVersion: Version(raw: "1.2.0")!,
            releaseChecker: StubChecker(result: .failure(ReleaseCheckingError.httpStatus(403)))
        )
        await controller.checkForUpdates()
        if case .failed(let message) = controller.phase {
            #expect(message.contains("403"))
        } else {
            Issue.record("expected failed phase, got \(controller.phase)")
        }
    }
}