import Foundation
import Testing
import WebKit

@testable import ChordEngine

/// A `.html` opened from Finder is a file URL, which a plain request can't
/// read. `loadPage` must load it with read access to its own folder, so the
/// page's relative resources come too.
@Suite("Loading a local page")
@MainActor
struct LoadPageTests {

    @Test("A local page loads with the stylesheet beside it")
    func filePageLoadsItsStylesheet() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("chord-load-page-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "body { color: rgb(1, 2, 3); }".write(
            to: folder.appendingPathComponent("style.css"), atomically: true, encoding: .utf8
        )
        let page = folder.appendingPathComponent("index.html")
        try "<link rel=stylesheet href=style.css><body>hi</body>".write(
            to: page, atomically: true, encoding: .utf8
        )

        let webView = WKWebView(frame: .zero)
        webView.loadPage(page)

        var color: String?
        for _ in 0..<100 {
            color = try? await webView.evaluateJavaScript(
                "document.styleSheets.length === 1 && document.readyState === 'complete'"
                    + " ? getComputedStyle(document.body).color : null"
            ) as? String
            if color != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(color == "rgb(1, 2, 3)")
    }
}
