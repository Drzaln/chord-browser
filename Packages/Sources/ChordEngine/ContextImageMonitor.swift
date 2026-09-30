import Foundation
import WebKit

/// Reports the URL of the image under the pointer when a context menu is about
/// to open, so the app can make "Download Image" actually download.
///
/// WebKit's own `WKMenuItemIdentifierDownloadImage` does not save the image in
/// this engine — choosing it arrives as an ordinary navigation to the image, so
/// it renders in the tab instead. The URL is captured from inside the page the
/// same way `ContextLinkMonitor` captures a link: a capture-phase `contextmenu`
/// listener walks up to the nearest `<img>` and posts its `currentSrc`. The
/// message is asynchronous, but only the *action* reads it, long after the menu
/// was built.
enum ContextImageMonitor {
    static let messageName = "chordContextImage"

    @MainActor
    static func makeUserScript() -> WKUserScript {
        WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    /// Parses a message body into the image URL, or `nil` when the right-click
    /// was not over an image. `data:` is allowed — a page may inline the image.
    static func imageURL(from body: Any) -> URL? {
        guard let string = body as? String, !string.isEmpty,
              let url = URL(string: string), let scheme = url.scheme,
              scheme == "http" || scheme == "https" || scheme == "data"
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
            while (node && node.tagName !== 'IMG') { node = node.parentElement; }
            handler.postMessage(node ? (node.currentSrc || node.src || '') : '');
        }, true);
    })();
    """
}
