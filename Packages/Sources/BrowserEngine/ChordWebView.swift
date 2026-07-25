import AppKit
import WebKit

/// A `WKWebView` that adds "Open in Little Chord" to the context menu of a link
/// (non-spec: user-requested).
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
    /// Invoked with that URL when the user chooses "Open in Little Chord".
    var onOpenInLittleArc: ((URL) -> Void)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard menuTargetsLink(menu) else { return }

        let item = NSMenuItem(
            title: "Open in Little Chord",
            action: #selector(openInLittleArc(_:)),
            keyEquivalent: ""
        )
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
    }

    /// A link context is exactly when WebKit put a link item in the menu.
    private func menuTargetsLink(_ menu: NSMenu) -> Bool {
        menu.items.contains { item in
            guard let id = item.identifier?.rawValue else { return false }
            return id.contains("OpenLink") || id.contains("CopyLink")
                || id.contains("DownloadLinkedFile")
        }
    }

    @objc private func openInLittleArc(_ sender: Any?) {
        guard let url = contextLinkURL?() else { return }
        onOpenInLittleArc?(url)
    }
}
