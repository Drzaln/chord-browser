import WebKit
import Testing

@testable import ChordEngine

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

    @Test("Mutes the ad and restores the prior mute with the rate")
    func mutesAdsAndRestores() {
        let source = YouTubeAdBlocker.makeUserScript().source
        // The ad is force-muted so the 10x blast never blasts audio...
        #expect(source.contains("video.muted = true"))
        // ...and the previous muted value (AudioMuteController's applied state)
        // is saved and restored, so a user's own mute choice survives the ad.
        #expect(source.contains("__chordPrevMuted"))
        #expect(source.contains("__chordAdMuted"))
    }

    @Test("Dismantles the anti-adblock enforcement wall instead of hiding it")
    func dismantlesEnforcementWall() {
        let source = YouTubeAdBlocker.makeUserScript().source
        // Hiding the wall's dialog alone is not enough: its modal overlay
        // stays open and pins a backdrop that freezes the whole page. The
        // script must remove the wall and undo the overlay's backdrop/scroll
        // lock so the page stays interactive after an ad.
        #expect(source.contains("ytd-enforcement-message-view-model"))
        #expect(source.contains("tp-yt-iron-overlay-backdrop"))
        #expect(source.contains("dismantleEnforcementWall"))
        #expect(source.contains("MutationObserver"))
    }
}
