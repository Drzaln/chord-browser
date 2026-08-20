import Foundation
import WebKit

/// Reports the URL of the link under the pointer when a context menu is about to
/// open, so the app can offer "Open in Little Chord" on links (non-spec:
/// user-requested).
///
/// macOS `WKWebView` does not hand the hovered element to `willOpenMenu`, and
/// the `contextMenuConfigurationForElement` delegate is iOS-only. So the link is
/// captured from inside the page: a capture-phase `contextmenu` listener walks up
/// to the nearest anchor and posts its `href`. The message crosses the process
/// boundary asynchronously, which is why the menu item's *visibility* is decided
/// from the native menu (synchronous) and only its *URL* comes from here — by the
/// time the user actually clicks, the value has long since arrived. See
/// `ChordWebView`.
enum ContextLinkMonitor {
    static let messageName = "chordContextLink"

    @MainActor
    static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    /// Parses a message body into the link URL, or `nil` when the right-click was
    /// not over a link.
    static func linkURL(from body: Any) -> URL? {
        guard let string = body as? String, !string.isEmpty else { return nil }
        guard let url = URL(string: string), let scheme = url.scheme,
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

        document.addEventListener('contextmenu', function (event) {
            var node = event.target;
            while (node && node.tagName !== 'A') { node = node.parentElement; }
            handler.postMessage(node && node.href ? node.href : '');
        }, true);
    })();
    """
}
