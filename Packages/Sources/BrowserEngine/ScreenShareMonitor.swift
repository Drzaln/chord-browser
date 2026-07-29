import Foundation
import WebKit

/// Reports whether a page is screen-sharing, and lets the app stop it.
///
/// WebKit exposes no display-capture state — there is no `WKMediaCaptureType`
/// for the screen and no property equivalent to `cameraCaptureState`, verified
/// against WKUIDelegate.h — so "is this pane sharing its screen" is observed
/// from inside the page, the same tactic `MediaActivityMonitor` uses for audio
/// (BROWSER_SPEC 11: no shipping against SPI).
///
/// A user script wraps `navigator.mediaDevices.getDisplayMedia`, calling through
/// to the real implementation and only *watching* the streams it hands back — it
/// does not intercept or replace the media, so the site's own WebRTC path is
/// untouched. It posts `{ sharing: true }` when a stream starts and
/// `{ sharing: false }` when the last one ends, and exposes
/// `window.__chordStopSharing()` so the native "Stop" control can end capture.
///
/// This is deliberately *not* an attempt to add "Share this tab": that would
/// mean feeding native frames back into the page's WebRTC connection, which the
/// public SDK cannot do. This only surfaces and controls sharing the user has
/// already started through WebKit's own Screen/Window picker.
enum ScreenShareMonitor {
    static let messageName = "screenShareActivity"

    /// Injected at document start into every frame, so a share begun before the
    /// page finishes loading is still noticed.
    @MainActor
    static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    /// Parses a message body into "is this pane screen-sharing".
    static func isScreenSharing(from body: Any) -> Bool? {
        guard let payload = body as? [String: Any],
              let sharing = payload["sharing"] as? Bool
        else { return nil }
        return sharing
    }

    /// JS that stops every display-capture track the page holds. Idempotent.
    static let stopScript = "window.__chordStopSharing && window.__chordStopSharing();"

    private static let source = """
    (function () {
        var md = navigator.mediaDevices;
        var handler = window.webkit
            && window.webkit.messageHandlers
            && window.webkit.messageHandlers.\(messageName);
        if (!md || typeof md.getDisplayMedia !== 'function' || !handler) { return; }

        // Install exactly once per window. `atDocumentStart` can run more than
        // once against the same page (re-injection, about:blank handovers); a
        // second run must NOT rebind `original` to our own wrapper (infinite
        // recursion) nor redefine the stop hook over a fresh, empty `active` —
        // that was the bug where Stop reported "not sharing" but stopped no
        // tracks, so the site kept sharing. The tracked streams live on `window`
        // so the one override and the one stop hook always share them.
        if (window.__chordShare) {
            window.__chordShare.handler = handler;
            return;
        }
        var state = { active: [], handler: handler };
        window.__chordShare = state;

        var original = md.getDisplayMedia.bind(md);

        function report() {
            state.handler.postMessage({ sharing: state.active.length > 0 });
        }

        function forget(stream) {
            var i = state.active.indexOf(stream);
            if (i !== -1) { state.active.splice(i, 1); report(); }
        }

        md.getDisplayMedia = function (constraints) {
            return original(constraints).then(function (stream) {
                state.active.push(stream);
                report();
                stream.getTracks().forEach(function (track) {
                    // Fires when the user ends the share from the OS UI, or the
                    // source goes away. `stop()` (below) does not fire this, so
                    // the stop hook reports separately.
                    track.addEventListener('ended', function () {
                        var live = stream.getTracks().some(function (t) {
                            return t.readyState === 'live';
                        });
                        if (!live) { forget(stream); }
                    });
                });
                return stream;
            });
        };

        window.__chordStopSharing = function () {
            state.active.forEach(function (stream) {
                stream.getTracks().forEach(function (track) { track.stop(); });
            });
            state.active = [];
            report();
        };
    })();
    """
}
