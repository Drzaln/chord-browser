import Foundation
import Testing
import WebKit

@testable import ChordExtensions

/// c1k.5: the popup measured its page on a clock for as long as it was open.
/// After its first two seconds it now waits for the page to change.
@Suite("Popup follows its page's changes")
@MainActor
struct ExtensionPopupSizingTests {

    @Test("The wait ends when the page grows, and not before")
    func waitsForAChange() async throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        web.loadHTMLString("<p>Short</p>", baseURL: nil)
        for _ in 0..<60 where web.isLoading { try await Task.sleep(for: .milliseconds(50)) }

        var changed = false
        web.callAsyncJavaScript(
            ExtensionPopup.nextChange, arguments: [:], in: nil, in: .page
        ) { _ in changed = true }
        try await Task.sleep(for: .milliseconds(600))
        #expect(!changed)

        _ = try await web.evaluateJavaScript("""
            document.body.insertAdjacentHTML('beforeend', '<div style="height:400px"></div>'); true
            """)
        for _ in 0..<40 where !changed { try await Task.sleep(for: .milliseconds(50)) }
        #expect(changed)
    }
}
