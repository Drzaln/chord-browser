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

    /// The tick keeps the player it found rather than querying for it four
    /// times a second, so a player YouTube swaps out must be looked up again:
    /// a stale one still carrying `ad-showing` would run real content at 10x.
    @Test("A replaced player is read afresh, in a real page")
    func followsAReplacedPlayer() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(YouTubeAdBlocker.makeUserScript())
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(
            """
            <div id="p1" class="html5-video-player ad-showing"><video id="v1"></video></div>
            """,
            baseURL: URL(string: "https://www.youtube.com/")
        )
        #expect(try await eventually(webView, "document.getElementById('v1')?.playbackRate === 10"))

        _ = try await webView.evaluateJavaScript("""
            document.getElementById('p1').remove();
            document.body.insertAdjacentHTML('beforeend',
                '<div id="p2" class="html5-video-player"><video id="v2"></video></div>');
            true
            """)
        // Several ticks' worth: content must stay at its own rate.
        try await Task.sleep(for: .milliseconds(800))
        #expect(try await webView.evaluateJavaScript(
            "document.getElementById('v2').playbackRate") as? Double == 1)

        // And the new player's own ad is still caught.
        _ = try await webView.evaluateJavaScript(
            "document.getElementById('p2').classList.add('ad-showing'); true")
        #expect(try await eventually(webView, "document.getElementById('v2').playbackRate === 10"))
    }

    /// c1k.5: the tick ran four times a second on every YouTube page, ad or
    /// no ad. Now it follows the player's class and media events, with a
    /// slow backup tick.
    @Test("With no ad the tick barely runs; an ad still gets the rate at once")
    func tickFollowsEvents() async throws {
        let configuration = WKWebViewConfiguration()
        // Counts ticks: each one asks the player for the ad overlay.
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
                window.__ticks = 0;
                var q = Element.prototype.querySelector;
                Element.prototype.querySelector = function (s) {
                    if (s === '.ytp-ad-player-overlay') { window.__ticks++; }
                    return q.call(this, s);
                };
                """,
            injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        configuration.userContentController.addUserScript(YouTubeAdBlocker.makeUserScript())
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(
            #"<div id="p" class="html5-video-player"><video id="v"></video></div>"#,
            baseURL: URL(string: "https://www.youtube.com/")
        )
        #expect(try await eventually(webView, "document.getElementById('p')"))
        _ = try await webView.evaluateJavaScript("window.__ticks = 0; true")
        try await Task.sleep(for: .seconds(2.2))
        let idle = try await webView.evaluateJavaScript("window.__ticks") as? Int ?? 99
        // Was ~9 at four a second; the backup tick allows one or two.
        #expect(idle <= 2)

        let started = Date()
        _ = try await webView.evaluateJavaScript(
            "document.getElementById('p').classList.add('ad-showing'); true")
        #expect(try await eventually(webView, "document.getElementById('v').playbackRate === 10"))
        #expect(Date().timeIntervalSince(started) < 0.3)
    }

    private func eventually(_ webView: WKWebView, _ condition: String) async throws -> Bool {
        for _ in 0..<60 {
            if try await webView.evaluateJavaScript("!!(\(condition))") as? Bool == true { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}
