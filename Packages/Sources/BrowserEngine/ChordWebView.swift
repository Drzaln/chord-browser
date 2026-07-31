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
    /// Invoked with that URL when the user chooses "Open in Little Chord".
    var onOpenInLittleArc: ((URL) -> Void)?
    /// "Open Link in New Tab" — a background tab in this pane's own window.
    var onOpenInNewTab: ((URL) -> Void)?
    /// "Open Link in New Private Window".
    var onOpenInPrivateWindow: ((URL) -> Void)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
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
                action: #selector(openInLittleArc(_:)), keyEquivalent: ""
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

    @objc private func openInLittleArc(_ sender: Any?) {
        guard let url = contextLinkURL?() else { return }
        onOpenInLittleArc?(url)
    }

    @objc private func openInNewTab(_ sender: Any?) {
        guard let url = contextLinkURL?() else { return }
        onOpenInNewTab?(url)
    }

    @objc private func openInPrivateWindow(_ sender: Any?) {
        guard let url = contextLinkURL?() else { return }
        onOpenInPrivateWindow?(url)
    }
}
