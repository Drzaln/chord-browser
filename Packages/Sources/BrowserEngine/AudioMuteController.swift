import Foundation
import WebKit

/// Mutes a page's audio (non-spec: user-requested).
///
/// `WKWebView` has no public mute property on macOS (only capture-state APIs),
/// and BROWSER_SPEC 11 rules out SPI like `_muted`. So muting is done inside the
/// page: a script mutes every media element and re-mutes any that start playing,
/// toggled by `window.__chordSetMuted(bool)` which the engine calls via
/// `evaluateJavaScript`. Re-applied after each navigation because a reload builds
/// a fresh JS context. Main-frame only, like `evaluateJavaScript` — audio inside
/// cross-origin iframes is not reached, which is an accepted limitation.
enum AudioMuteController {
    /// The JS entry point the engine calls to set the mute state.
    static let setMutedFunction = "window.__chordSetMuted"

    @MainActor
    static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    private static let source = """
    (function () {
        var muted = false;

        function apply() {
            var media = document.querySelectorAll('audio, video');
            for (var i = 0; i < media.length; i++) { media[i].muted = muted; }
        }

        window.__chordSetMuted = function (value) {
            muted = !!value;
            apply();
        };

        // Re-mute anything that starts playing while muted (capture phase, since
        // media events do not bubble).
        document.addEventListener('play', function (event) {
            if (muted && event.target && 'muted' in event.target) {
                event.target.muted = true;
            }
        }, true);

        document.addEventListener('DOMContentLoaded', apply);
    })();
    """
}
