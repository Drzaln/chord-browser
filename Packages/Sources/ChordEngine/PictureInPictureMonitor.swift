import Foundation
import WebKit

/// App-driven Picture-in-Picture (non-spec: user-requested), the Orion-style
/// route: the *app* commands a `<video>` into PiP rather than waiting on the
/// page's `requestPictureInPicture()` API.
///
/// Why not the standard API: on a native-macOS `WKWebView` WebKit keeps
/// `document.pictureInPictureEnabled` false — the knob that turns it on,
/// `WKWebViewConfiguration.allowsPictureInPictureMediaPlayback`, is
/// iOS/Catalyst-only, and embedded web views get no presentation host. What *is*
/// exposed is the legacy WebKit presentation-mode API
/// (`video.webkitSupportsPresentationMode` / `webkitSetPresentationMode`), the
/// same path Safari's own PiP machinery uses — Orion's toolbar-PiP is built on
/// exactly this. That is what this monitor drives.
///
/// Two halfs, matching the in-page-monitor pattern used across this package:
/// a *command* script (run on demand, returns what happened) and a *watcher*
/// script (posts `{ active: Bool }` whenever a video's presentation mode
/// changes, so the View menu's Enter/Exit label stays honest even when the
/// change did not start from the command — the PiP window's own close button,
/// the video controls' PiP button). The watcher posts only on events, never on
/// a timer, so its idle cost is zero.
enum PictureInPictureMonitor {
    static let messageName = "pictureInPictureActivity"

    /// Injected at document start into every frame, so a mode change in an
    /// iframe player is still noticed. The watcher does no work at load — it
    /// only registers two passive listeners and waits for an event.
    @MainActor
    static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: watcherSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    /// Parses a message body into "is this page's video in PiP".
    static func isActive(from body: Any) -> Bool? {
        guard let payload = body as? [String: Any],
              let active = payload["active"] as? Bool
        else { return nil }
        return active
    }

    /// Maps the toggle script's return object onto the seam's outcome. Anything
    /// unrecognised reads as `.noVideo` — the only meaningful failure a page
    /// can report through this channel.
    static func result(from dict: [String: Any]?) -> PictureInPictureResult {
        guard let action = dict?["action"] as? String else { return .unsupported }
        switch action {
        case "entered": return .entered
        case "exited": return .exited
        default: return .noVideo
        }
    }

    /// The command half. Runs once, in the page world, on the main frame only.
    ///
    /// Returns its outcome via a top-level `return`, the same shape the codec
    /// probes use: `callAsyncJavaScript` evaluates the body as a *function*, so
    /// a value wrapped in an IIFE whose `return` lands inside the IIFE is
    /// swallowed and the call resolves `undefined` — which made the first
    /// version of this silently do nothing.
    ///
    /// Picks a video by linear scan — no sort, no allocation beyond the
    /// candidate list — and drives `webkitSetPresentationMode`. Exiting takes
    /// priority: a video already in PiP must be released before anything else.
    /// The chosen video is the one most likely to be what the user is watching:
    /// playing beats paused, and among equals the largest surface wins. Videos
    /// with nothing loaded (`readyState == 0`) are skipped so PiP never opens a
    /// blank frame.
    ///
    /// Light-DOM `querySelectorAll` finds the player on YouTube and most video
    /// sites, so the common path is a single scan. Only when it finds nothing
    /// do we pay the cost of walking shadow roots — some players hide their
    /// `<video>` behind a custom element's shadow DOM.
    static let toggleScript = """
    function piPable(video) {
        return !!(video.webkitSupportsPresentationMode
            && video.webkitSupportsPresentationMode('picture-in-picture'));
    }
    function collectVideos() {
        var found = document.querySelectorAll('video');
        var videos = [];
        for (var i = 0; i < found.length; i++) { videos.push(found[i]); }
        if (found.length) { return videos; }
        function walk(root) {
            var nodes = root.querySelectorAll('*');
            for (var i = 0; i < nodes.length; i++) {
                var n = nodes[i];
                if (n.tagName === 'VIDEO') { videos.push(n); }
                if (n.shadowRoot) { walk(n.shadowRoot); }
            }
        }
        walk(document);
        return videos;
    }
    var videos = collectVideos();
    if (!videos.length) { return { action: 'noVideo' }; }

    // `webkitSetPresentationMode` can return without error and *not* engage
    // (a macOS WKWebView without the private `allowsPictureInPictureMediaPlayback`
    // preference silently no-ops). So every request verifies the mode actually
    // flipped before reporting success — a bounded poll, because the mode
    // change travels through WebKit's UI process and is not synchronous.
    function waitForMode(video, mode) {
        return new Promise(function (resolve) {
            var deadline = Date.now() + 1000;
            (function poll() {
                if (video.webkitPresentationMode === mode) { resolve(true); return; }
                if (Date.now() >= deadline) { resolve(false); return; }
                setTimeout(poll, 25);
            })();
        });
    }

    for (var i = 0; i < videos.length; i++) {
        if (videos[i].webkitPresentationMode === 'picture-in-picture') {
            try {
                videos[i].webkitSetPresentationMode('inline');
                var left = await waitForMode(videos[i], 'inline');
                return { action: left ? 'exited' : 'unsupported' };
            } catch (e) {
                return { action: 'unsupported' };
            }
        }
    }

    var best = null;
    var bestScore = -1;
    for (var i = 0; i < videos.length; i++) {
        var v = videos[i];
        if (v.readyState === 0) { continue; }
        var area = (v.videoWidth || 0) * (v.videoHeight || 0);
        var score = (v.paused ? 0 : 1) * 1000000 + area;
        if (score > bestScore) { bestScore = score; best = v; }
    }
    if (!best) { return { action: 'noVideo' }; }

    try {
        best.webkitSetPresentationMode('picture-in-picture');
        var engaged = await waitForMode(best, 'picture-in-picture');
        if (engaged) { return { action: 'entered' }; }
        return { action: 'unsupported' };
    } catch (e) {
        return { action: 'unsupported' };
    }
    """

    /// The watcher half. Event-only: it posts exactly when a video's
    /// presentation mode flips, deduplicated per frame. The mode change fires
    /// on the video element itself, so the report reads the event's composed
    /// target (the real element, even through a shadow root, where
    /// `event.target` would be retargeted to the host) instead of rescanning
    /// the DOM — O(1) per event, and a `{ active: false }` post can only mean
    /// PiP genuinely ended: only one video can float at a time, so a frame with
    /// no PiP'd video never posts on another frame's event, and the aggregated
    /// flag cannot flicker.
    private static let watcherSource = """
    (function () {
        var handler = window.webkit
            && window.webkit.messageHandlers
            && window.webkit.messageHandlers.\(messageName);
        if (!handler) { return; }
        // `atDocumentStart` can run more than once per document; keep one set
        // of listeners and one dedupe state per window.
        if (window.__chordPip) {
            window.__chordPip.handler = handler;
            return;
        }
        var lastReported = null;
        window.__chordPip = { handler: handler };

        function report(e) {
            var path = e && e.composedPath ? e.composedPath() : null;
            var v = (path && path[0]) || (e && e.target);
            if (!v || v.nodeType !== 1 || v.tagName !== 'VIDEO') { return; }
            var active = v.webkitPresentationMode === 'picture-in-picture';
            if (active === lastReported) { return; }
            lastReported = active;
            handler.postMessage({ active: active });
        }

        // Presentation-mode changes do not bubble; the capture phase catches
        // them at any depth. The webkit-prefixed name is the one
        // `webkitSetPresentationMode` fires; the unprefixed alias covers newer
        // WebKit.
        ['webkitpresentationmodechanged', 'presentationmodechanged'].forEach(function (name) {
            document.addEventListener(name, report, true);
        });
    })()
    """
}