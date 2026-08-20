import Foundation
import WebKit

/// Reports whether a page is playing audio.
///
/// `WKWebView` has no public audio-playback property — only `cameraCaptureState`
/// and `microphoneCaptureState`, which are about capture, not playback.
/// `_isPlayingAudio` exists but is SPI, and BROWSER_SPEC 11 rules out shipping
/// against API we cannot see in the SDK.
///
/// So playback is observed from inside the page instead: a user script listens
/// for media events and posts a message when the set of playing elements
/// changes. This is public, supported, and enough for the sweep's purpose —
/// don't close a tab that is making noise (4.3). See ADR 008.
enum MediaActivityMonitor {
    static let messageName = "mediaActivity"

    /// Injected at document start into every frame, so audio started before the
    /// page finishes loading is still noticed.
    @MainActor
    static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    /// Parses a message body into "is this pane playing audio".
    static func isPlayingAudio(from body: Any) -> Bool? {
        guard let payload = body as? [String: Any],
              let playing = payload["playing"] as? Bool
        else { return nil }
        return playing
    }

    private static let source = """
    (function () {
        var handler = window.webkit
            && window.webkit.messageHandlers
            && window.webkit.messageHandlers.\(messageName);
        if (!handler) { return; }

        var lastReported = null;

        function isAudible(element) {
            return !element.paused && !element.muted && element.volume > 0;
        }

        function report() {
            var elements = document.querySelectorAll('audio, video');
            var playing = false;
            for (var i = 0; i < elements.length; i++) {
                if (isAudible(elements[i])) { playing = true; break; }
            }
            if (playing === lastReported) { return; }
            lastReported = playing;
            handler.postMessage({ playing: playing });
        }

        // Capture phase: media events do not bubble.
        ['play', 'pause', 'ended', 'volumechange', 'emptied'].forEach(function (name) {
            document.addEventListener(name, report, true);
        });

        document.addEventListener('DOMContentLoaded', report);
        report();
    })();
    """
}
