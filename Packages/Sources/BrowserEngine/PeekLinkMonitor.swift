import Foundation
import WebKit

/// Reports the link under the pointer while ⌘ is held, for the Cmd+hover Peek
/// preview (non-spec: user-requested).
///
/// A capture-phase `mousemove` listener posts a link's `href` when ⌘ is down and
/// the pointer is over an anchor, and an empty string to dismiss when it is not
/// (⌘ released, pointer left the link, window blurred). Deduped by href so a
/// steady hover posts once. The panel is positioned from the live mouse location
/// on the native side, so no coordinates are sent.
enum PeekLinkMonitor {
    static let messageName = "chordPeekLink"

    @MainActor
    static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    /// The link to preview, or `nil` to dismiss the preview.
    static func linkURL(from body: Any) -> URL? {
        guard let string = body as? String, !string.isEmpty,
              let url = URL(string: string), let scheme = url.scheme,
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    private static let source = """
    (function () {
        var handler = window.webkit
            && window.webkit.messageHandlers
            && window.webkit.messageHandlers.\(messageName);
        if (!handler) { return; }

        var lastHref = null;
        // A hover is the weakest signal of intent there is, and each preview
        // builds a real web view and fetches the page. Without a settle the
        // pointer merely *crossing* a list of links with Cmd down opens one per
        // link. 250ms is long enough that only a deliberate rest triggers it,
        // short enough that a deliberate rest does not feel stalled.
        var DWELL_MS = 250;
        var pending = null;
        var pendingHref = null;

        function cancelPending() {
            if (pending !== null) { clearTimeout(pending); pending = null; pendingHref = null; }
        }

        function anchor(node) {
            while (node && node.tagName !== 'A') { node = node.parentElement; }
            return node;
        }

        function hide() {
            cancelPending();
            if (lastHref !== null) { lastHref = null; handler.postMessage(''); }
        }

        document.addEventListener('mousemove', function (event) {
            if (!event.metaKey) { hide(); return; }
            var link = anchor(event.target);
            if (link && link.href) {
                // Already showing this one: nothing to do, and do not restart
                // the clock — a twitch inside the link must not re-open it.
                if (link.href === lastHref) { return; }
                if (link.href === pendingHref) { return; }
                cancelPending();
                pendingHref = link.href;
                pending = setTimeout(function () {
                    pending = null;
                    var href = pendingHref;
                    pendingHref = null;
                    lastHref = href;
                    handler.postMessage(href);
                }, DWELL_MS);
            } else {
                hide();
            }
        }, true);

        document.addEventListener('keyup', function (event) {
            if (event.key === 'Meta') { hide(); }
        }, true);
        document.addEventListener('mouseleave', hide, true);
        window.addEventListener('blur', hide, true);
    })();
    """
}
