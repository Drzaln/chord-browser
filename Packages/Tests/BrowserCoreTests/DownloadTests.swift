import Foundation
import Testing

@testable import BrowserCore

@Suite("Download naming and progress")
struct DownloadTests {

    @Test("An unused filename is taken as-is")
    func usesSuggestedName() {
        let directory = URL(filePath: "/tmp/downloads")
        let url = DownloadNaming.uniqueURL(
            for: "report.pdf", in: directory, exists: { _ in false }
        )
        #expect(url.lastPathComponent == "report.pdf")
    }

    /// WebKit rejects a destination that already exists, so this is required for
    /// the download to start at all, not a nicety.
    @Test("A taken filename is suffixed rather than overwritten")
    func avoidsCollision() {
        let directory = URL(filePath: "/tmp/downloads")
        let taken: Set<String> = ["/tmp/downloads/report.pdf", "/tmp/downloads/report-1.pdf"]

        let url = DownloadNaming.uniqueURL(
            for: "report.pdf", in: directory, exists: { taken.contains($0.path) }
        )
        #expect(url.lastPathComponent == "report-2.pdf")
    }

    @Test("An extensionless name still gets a suffix")
    func collisionWithoutExtension() {
        let directory = URL(filePath: "/tmp/downloads")
        let url = DownloadNaming.uniqueURL(
            for: "LICENSE",
            in: directory,
            exists: { $0.path == "/tmp/downloads/LICENSE" }
        )
        #expect(url.lastPathComponent == "LICENSE-1")
    }

    /// The suggested filename comes from web content, so it is not trusted.
    @Test(
        "A hostile suggested filename cannot escape the downloads directory",
        arguments: [
            ("../../etc/passwd", "passwd"),
            ("/etc/passwd", "passwd"),
            ("../../../a.zip", "a.zip"),
            (".hidden", "hidden"),
            ("", "download"),
            ("..", "download"),
            ("...", "download"),
        ]
    )
    func sanitizesFilename(suggested: String, expected: String) {
        #expect(DownloadNaming.sanitize(suggested) == expected)
    }

    @Test("A download with no declared length reports no fraction")
    func unknownLengthHasNoFraction() {
        let item = DownloadItem(
            url: URL(string: "https://example.com/a.zip")!,
            filename: "a.zip",
            bytesReceived: 1024,
            bytesExpected: -1,
            startedAt: .now
        )
        // A determinate bar pinned at zero reads as a hang; callers must show an
        // indeterminate one instead.
        #expect(item.fractionCompleted == nil)
    }

    @Test("Fraction is bytes over total, and never exceeds 1")
    func fraction() {
        var item = DownloadItem(
            url: URL(string: "https://example.com/a.zip")!,
            filename: "a.zip",
            bytesReceived: 50,
            bytesExpected: 200,
            startedAt: .now
        )
        #expect(item.fractionCompleted == 0.25)

        // Servers do occasionally send more than they promised.
        item.bytesReceived = 500
        #expect(item.fractionCompleted == 1)
    }

    @Test("Only an in-progress download counts as active")
    func activeState() {
        var item = DownloadItem(
            url: URL(string: "https://example.com/a.zip")!,
            filename: "a.zip",
            startedAt: .now
        )
        #expect(item.isActive)

        item.state = .finished
        #expect(!item.isActive)

        item.state = .failed(message: "boom", canResume: true)
        #expect(!item.isActive)
    }
}
