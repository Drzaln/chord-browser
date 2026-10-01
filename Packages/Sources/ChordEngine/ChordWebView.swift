import AppKit
import WebKit

/// A `WKWebView` that adds our own items to the context menu of a link
/// (non-spec: user-requested): open it in a new tab, in a new private window, or
/// in Little Chord.
///
/// WebKit's own menu offers "Open Link in New Window" and nothing tab-aware —
/// "Open Link in New Tab" is Safari's, not WebKit's, because tabs are the app's
/// concept and not the engine's. So it is ours to add.
///
/// Whether the click was on a link is read from the native menu WebKit builds —
/// it carries stable item identifiers (`WKMenuItemIdentifierOpenLink`,
/// `…CopyLink`, …) that are present only for links, and that check is
/// synchronous and reliable. The link's URL comes from `contextLinkURL`, fed by
/// `ContextLinkMonitor`; it is read lazily when the user picks the item, by which
/// point the page's asynchronously-posted href has arrived.
@MainActor
final class ChordWebView: WKWebView {
    /// The URL of the most recently right-clicked link, resolved at click time.
    var contextLinkURL: (() -> URL?)?
    /// The URL of the most recently right-clicked image, resolved at click time.
    var contextImageURL: (() -> URL?)?
    /// Invoked with that URL when the user chooses "Open in Little Chord".
    var onOpenInLittleChord: ((URL) -> Void)?
    /// "Open Link in New Tab" — a background tab in this pane's own window.
    var onOpenInNewTab: ((URL) -> Void)?
    /// "Open Link in New Private Window".
    var onOpenInPrivateWindow: ((URL) -> Void)?
    /// "Download Image" — actually saves the right-clicked image.
    var onDownloadImage: ((URL) -> Void)?
    /// "Search with Google" on selected text — searches in a new tab in-app,
    /// instead of WebKit handing the query to the system default browser.
    var onSearchWeb: ((String) -> Void)?
    /// The configured search provider's name, so the item reads "Search with
    /// Brave" and not WebKit's fixed "Google".
    var searchEngineName: (() -> String)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        // WebKit's own "Download Image" does not download: in this engine the
        // item arrives as an ordinary navigation to the image, which renders it
        // in the tab instead of saving it. Take the item over and save the image
        // ourselves.
        if let item = menu.items.first(where: {
            $0.identifier?.rawValue.contains("DownloadImage") == true
        }) {
            item.target = self
            item.action = #selector(downloadImage(_:))
        }

        // "Search with Google" would open the system default browser (Safari).
        // Take it over so the query searches in a new tab here instead.
        if let item = menu.items.first(where: {
            $0.identifier?.rawValue.contains("SearchWeb") == true
        }) {
            item.title = "Search with \(searchEngineName?() ?? "Google")"
            item.target = self
            item.action = #selector(searchWeb(_:))
        }

        guard menuTargetsLink(menu) else { return }

        // Inserted at the top, in the order other browsers use: the tab first,
        // because it is the one people reach for constantly.
        let items = [
            NSMenuItem(
                title: "Open Link in New Tab",
                action: #selector(openInNewTab(_:)), keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Open Link in New Private Window",
                action: #selector(openInPrivateWindow(_:)), keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Open in Little Chord",
                action: #selector(openInLittleChord(_:)), keyEquivalent: ""
            ),
        ]
        for (offset, item) in items.enumerated() {
            item.target = self
            menu.insertItem(item, at: offset)
        }
        menu.insertItem(.separator(), at: items.count)
    }

    /// A link context is exactly when WebKit put a link item in the menu.
    private func menuTargetsLink(_ menu: NSMenu) -> Bool {
        menu.items.contains { item in
            guard let id = item.identifier?.rawValue else { return false }
            return id.contains("OpenLink") || id.contains("CopyLink")
                || id.contains("DownloadLinkedFile")
        }
    }

    @objc private func openInLittleChord(_ sender: Any?) {
        guard let url = contextLinkURL?() else { return }
        onOpenInLittleChord?(url)
    }

    @objc private func openInNewTab(_ sender: Any?) {
        guard let url = contextLinkURL?() else { return }
        onOpenInNewTab?(url)
    }

    @objc private func openInPrivateWindow(_ sender: Any?) {
        guard let url = contextLinkURL?() else { return }
        onOpenInPrivateWindow?(url)
    }

    @objc private func downloadImage(_ sender: Any?) {
        guard let url = contextImageURL?() else { return }
        onDownloadImage?(url)
    }

    @objc private func searchWeb(_ sender: Any?) {
        // The selected text is still live at click time; read it, then hand the
        // query up to search in-app.
        evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self, let text = result as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return }
                self.onSearchWeb?(text)
            }
        }
    }
}
