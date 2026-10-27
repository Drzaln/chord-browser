import AppKit
import Foundation
import WebKit

/// An extension's action popup, in a popover of the browser's own.
///
/// WebKit offers a popover too, and it works for most extensions — but for
/// some, messages from WebKit's popup never reach the worker while the same
/// page in a view built from the extension's configuration does. So the popup
/// page is loaded here, in such a view, hanging from the extension's button.
///
/// Chrome sizes a popup to its content, 25–800 points wide and up to 600 tall;
/// the page is measured after load and again as it settles. `window.close()`
/// closes it, and a link that asks for a new window opens as a tab.
@MainActor
final class ExtensionPopup: NSObject, WKUIDelegate, WKNavigationDelegate, NSPopoverDelegate {
    static let shared = ExtensionPopup()

    private var popover: NSPopover?
    private var web: WKWebView?
    private var page: PopupPage?
    private var extensionID: String?
    private weak var button: NSView?
    private var sizing: Timer?
    private var shown = false
    private var ticks = 0
    /// Called when the popup goes away, for the host's sidebar-hold signal.
    var onClose: (() -> Void)?
    private static var lastSize: [String: NSSize] = [:]

    var isUp: Bool { popover?.isShown == true }
    var view: WKWebView? { web }

    func show(
        _ url: URL, for context: WKWebExtensionContext, from anchor: NSView?,
        host: WebKitExtensionHost, spaceID: UUID
    ) {
        close()
        guard let configuration = context.webViewConfiguration else { return }
        let size = Self.lastSize[context.uniqueIdentifier] ?? NSSize(width: 360, height: 240)
        let web = WKWebView(
            frame: NSRect(origin: .zero, size: size), configuration: configuration
        )
        web.uiDelegate = self
        web.navigationDelegate = self
        web.alphaValue = 0
        web.load(URLRequest(url: url))

        let controller = NSViewController()
        controller.view = web
        controller.preferredContentSize = size
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = size
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        self.web = web
        self.popover = popover
        extensionID = context.uniqueIdentifier
        button = anchor
        let page = PopupPage(
            web: web, context: context, host: host, spaceID: spaceID
        )
        self.page = page
        context.didOpenTab(page)

        if let anchor, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else if let content = NSApp.mainWindow?.contentView {
            popover.show(
                relativeTo: NSRect(x: content.bounds.maxX - 40, y: content.bounds.maxY - 40,
                                   width: 1, height: 1),
                of: content, preferredEdge: .minY
            )
        }
        // A page that never finishes loading is still shown, at its last
        // remembered size.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.reveal()
        }
    }

    private func reveal() {
        guard !shown, let web, let popover else { return }
        shown = true
        // The popover may clamp its width at the screen edge; the page must
        // fill what is actually shown, not the requested content size.
        let size = popover.contentViewController?.view.bounds.size
            ?? popover.contentSize
        web.frame = NSRect(origin: .zero, size: size)
        web.autoresizingMask = [.width, .height]
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            web.animator().alphaValue = 1
        }
    }

    private func measure(then: (() -> Void)? = nil) {
        guard let web else { return }
        web.evaluateJavaScript(Self.preferred) { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self, web === self.web else { return }
                if let pair = value as? [Double], pair.count == 2 {
                    let size = NSSize(width: pair[0], height: pair[1])
                    if let popover = self.popover {
                        popover.contentSize = size
                        popover.contentViewController?.preferredContentSize = size
                        popover.contentViewController?.view.setFrameSize(size)
                        if self.shown { web.frame = NSRect(origin: .zero, size: size) }
                    }
                    if let id = self.extensionID { Self.lastSize[id] = size }
                }
                self.reveal()
                then?()
            }
        }
    }

    func close() {
        sizing?.invalidate()
        sizing = nil
        let closing = popover
        forget()
        closing?.performClose(nil)
    }

    private func forget() {
        if let page { page.context?.didCloseTab(page, windowIsClosing: false) }
        page = nil
        popover = nil
        web = nil
        extensionID = nil
        button = nil
        shown = false
        ticks = 0
        let closed = onClose
        onClose = nil
        closed?()
    }

    /// A press on the extension's own button closes an open popup, and the
    /// button's click must not immediately reopen it.
    private var closedByButton: (id: String, at: Date)?
    func closes(_ id: String) -> Bool {
        defer { closedByButton = nil }
        if isUp, extensionID == id {
            close()
            return true
        }
        guard let closed = closedByButton, closed.id == id else { return false }
        return Date().timeIntervalSince(closed.at) < 1.5
    }

    func popoverWillClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover, let id = extensionID,
              let button, let window = button.window, let event = NSApp.currentEvent,
              event.window === window,
              event.type == .leftMouseDown || event.type == .leftMouseUp
        else { return }
        let spot = button.convert(event.locationInWindow, from: nil)
        if button.bounds.contains(spot) { closedByButton = (id, Date()) }
    }

    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        sizing?.invalidate()
        sizing = nil
        forget()
    }

    // MARK: - Page behaviour

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web else { return }
        measure()
        guard sizing == nil else { return }
        ticks = 0
        sizing = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.web != nil else { return }
                self.ticks += 1
                if self.ticks > 8 {
                    self.sizing?.invalidate()
                    self.sizing = nil
                    return
                }
                self.measure()
            }
        }
    }

    func webViewDidClose(_ webView: WKWebView) { close() }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = action.request.url, let pane = page {
            _ = pane.host?.tabModel?.extensionCreateTab(
                url: url, inSpace: pane.spaceID, active: true
            )
        }
        close()
        return nil
    }

    /// Chrome's auto-size: the page's own width if it names one, otherwise its
    /// narrowest layout, clamped the way Blink clamps a popup; then its height.
    static let preferred = """
    (() => {
      const d = document.documentElement;
      const v = document.compatMode === "BackCompat" ? document.body : d;
      if (!v) return null;
      const saved = d.getAttribute("style");
      const back = () => saved === null ? d.removeAttribute("style") : d.setAttribute("style", saved);
      const box = d.getBoundingClientRect();
      let w = box.width;
      if (Math.abs(w - v.clientWidth) <= 1) {
        d.style.setProperty("width", "min-content", "important");
        const narrowest = d.getBoundingClientRect().width;
        back();
        w = narrowest >= 100 ? narrowest : Math.max(narrowest, d.scrollWidth);
      }
      const gutter = innerWidth - v.clientWidth;
      w = Math.min(800, Math.max(25, Math.ceil(w + gutter)));
      d.style.setProperty("width", (w - gutter) + "px", "important");
      let h = d.getBoundingClientRect().height;
      if (Math.abs(h - innerHeight) <= 1) {
        d.style.setProperty("height", "auto", "important");
        d.style.setProperty("min-height", "0", "important");
        h = d.getBoundingClientRect().height;
      }
      back();
      return [w, Math.min(600, Math.max(25, Math.ceil(h + innerHeight - v.clientHeight)))];
    })()
    """
}

/// The popup page as WebKit sees it: in the browser's window, not among its
/// tabs — which is where Chrome puts a popup.
@MainActor
final class PopupPage: NSObject, WKWebExtensionTab {
    weak var web: WKWebView?
    weak var context: WKWebExtensionContext?
    weak var host: WebKitExtensionHost?
    let spaceID: UUID

    init(
        web: WKWebView, context: WKWebExtensionContext,
        host: WebKitExtensionHost, spaceID: UUID
    ) {
        self.web = web
        self.context = context
        self.host = host
        self.spaceID = spaceID
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        host?.windowAdapter(forSpace: spaceID)
    }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { NSNotFound }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    func title(for context: WKWebExtensionContext) -> String? { web?.title }
    func url(for context: WKWebExtensionContext) -> URL? { web?.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(web?.isLoading ?? false)
    }
    func isSelected(for context: WKWebExtensionContext) -> Bool { false }
    func close(for context: WKWebExtensionContext) async throws {
        ExtensionPopup.shared.close()
    }
}
