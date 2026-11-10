import Foundation
import WebKit

/// Reports the link under the pointer, so the pane can show where a link goes
/// before it is clicked (non-spec: user-requested).
///
/// WebKit tells an app this only through SPI (`mouseDidMoveOverElement`), so it
/// is read from inside the page, the way `ContextLinkMonitor` reads the link
/// under a right-click. The `href` is read by this script from the element
/// itself, already resolved by the browser: it is the address a click would
/// go to, whatever the link's text says.
///
/// Costs nothing while the pointer is still: three passive listeners, no
/// timer, and a message only when the link under the pointer changes.
enum LinkHoverMonitor {
    static let messageName = "chordLinkHover"
    /// Longer than any real address needs; bounds what a page can make the
    /// script post and the app lay out.
    static let maxLength = 2048

    @MainActor
    static func makeUserScript() -> WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    /// The hovered link from a message body, or nil when the pointer left it.
    static func link(from body: Any) -> URL? {
        guard let string = body as? String, !string.isEmpty, string.count <= maxLength,
              let url = URL(string: string), url.scheme != nil
        else { return nil }
        return url
    }

    private static let source = """
    (function () {
        var handler = window.webkit
            && window.webkit.messageHandlers
            && window.webkit.messageHandlers.\(messageName);
        if (!handler) { return; }
        var last = '';
        function say(value) {
            if (value !== last) { last = value; handler.postMessage(value); }
        }
        var quiet = { capture: true, passive: true };
        document.addEventListener('mouseover', function (event) {
            var target = event.target;
            var link = target && target.closest ? target.closest('a[href],area[href]') : null;
            var href = link && typeof link.href === 'string' ? link.href : '';
            say(href.length > \(maxLength) ? '' : href);
        }, quiet);
        document.addEventListener('mouseout', function (event) {
            if (!event.relatedTarget) { say(''); }
        }, quiet);
        window.addEventListener('scroll', function () { say(''); }, quiet);
    })();
    """
}
