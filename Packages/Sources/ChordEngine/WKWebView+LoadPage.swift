import WebKit

extension WKWebView {
    /// Loads a pane's URL, the one way a pane URL becomes a request.
    ///
    /// A local file (a `.html` opened from Finder, or such a tab restored) has
    /// to go through `loadFileURL`, which grants read access; a plain request
    /// for it loads nothing. Access is to the file's own folder only, so the
    /// page's relative CSS, images and scripts load and nothing else does.
    func loadPage(_ url: URL) {
        if url.isFileURL {
            loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            load(URLRequest(url: url))
        }
    }
}
