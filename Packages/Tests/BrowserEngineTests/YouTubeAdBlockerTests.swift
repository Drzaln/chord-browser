import WebKit
import Testing

@testable import BrowserEngine

/// The YouTube ad blocker is a pure page-side user script (no message handler),
/// so these guard its injection shape and that the JS still targets YouTube —
/// the parts a refactor could silently break.
@Suite("YouTube ad blocker")
@MainActor
struct YouTubeAdBlockerTests {

    @Test("Injected at document start, into every frame")
    func injectionShape() {
        let script = YouTubeAdBlocker.makeUserScript()
        #expect(script.injectionTime == .atDocumentStart)
        // Embeds and music.youtube.com are separate frames/documents.
        #expect(script.isForMainFrameOnly == false)
    }

    @Test("Guards to YouTube hosts and drives the player's ad state")
    func targetsYouTube() {
        let source = YouTubeAdBlocker.makeUserScript().source
        #expect(source.contains("youtube"))
        #expect(source.contains("ad-showing"))
        // Singleton guard, so re-injection is idempotent.
        #expect(source.contains("__chordYTAdBlock"))
    }
}
