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

        function anchor(node) {
            while (node && node.tagName !== 'A') { node = node.parentElement; }
            return node;
        }

        function hide() {
            if (lastHref !== null) { lastHref = null; handler.postMessage(''); }
        }

        document.addEventListener('mousemove', function (event) {
            if (!event.metaKey) { hide(); return; }
            var link = anchor(event.target);
            if (link && link.href) {
                if (link.href !== lastHref) {
                    lastHref = link.href;
                    handler.postMessage(link.href);
                }
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
