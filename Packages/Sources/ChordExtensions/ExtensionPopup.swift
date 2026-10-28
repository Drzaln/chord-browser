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
    private var stage: NSView?
    private var web: WKWebView?
    private var page: PopupPage?
    private var extensionID: String?
    private var capture: ExtensionCapture?
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
        // Chrome measures a popup while its view is still the 25-point
        // square; the page must not see the size it had last time yet.
        let web = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 25, height: 25),
            configuration: configuration
        )
        web.uiDelegate = self
        web.navigationDelegate = self
        web.alphaValue = 0
        Log.extensions.notice("popup: opening \(url.absoluteString)")
        web.load(URLRequest(url: url))

        // The page sits in a stage view: the popover takes its size from the
        // controller's view, and resizing the web view itself made Bitwarden
        // loop half/full/half. Search uses the same stage.
        let stage = NSView(frame: NSRect(origin: .zero, size: size))
        stage.addSubview(web)
        let controller = NSViewController()
        controller.view = stage
        controller.preferredContentSize = size
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = size
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        self.stage = stage
        self.web = web
        self.popover = popover
        extensionID = context.uniqueIdentifier
        capture = host.capture
        button = anchor
        let page = PopupPage(
            web: web, context: context, host: host, spaceID: spaceID
        )
        self.page = page
        context.didOpenTab(page)

        if let anchor, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else if let content = NSApp.mainWindow?.contentView {
            // No button to hang from — where the extension buttons would be,
            // at the window's top right. SwiftUI's content view is flipped,
            // so its top is minY.
            let bounds = content.bounds, flipped = content.isFlipped
            let spot = NSRect(
                x: bounds.maxX - 40,
                y: flipped ? bounds.minY + 40 : bounds.maxY - 40,
                width: 1, height: 1
            )
            popover.show(
                relativeTo: spot, of: content,
                preferredEdge: flipped ? .maxY : .minY
            )
        }
        // Not shown before it is measured: Bitwarden reads `innerHeight` once
        // as it starts and keeps the layout it finds for good, so a page shown
        // early at the remembered size (240 tall by default) stayed half
        // height. Measured when the document is built (see below) or has
        // loaded; a page slow to do either is measured anyway after a moment,
        // and shown regardless a little later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak popover] in
            guard let self, let popover, popover === self.popover else { return }
            self.firstMeasure()
            self.follow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak popover] in
            guard let self, let popover, popover === self.popover else { return }
            self.reveal()
        }
    }

    private func reveal() {
        guard !shown, let web, let popover else { return }
        shown = true
        // The popover may clamp its width at the screen edge; the page must
        // fill what is actually shown, not the requested content size.
        let size = stage?.bounds.size ?? popover.contentSize
        web.frame = NSRect(origin: .zero, size: size)
        web.autoresizingMask = [.width, .height]
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            web.animator().alphaValue = 1
        }
    }

    /// The document is built — DOMContentLoaded, the moment Chrome sizes a
    /// popup, before the page's scripts look at the room they have (Bitwarden
    /// takes whatever size it finds then for good). WebKit tells a navigation
    /// delegate that has this method.
    @objc(_webView:navigationDidFinishDocumentLoad:)
    func webView(_ webView: WKWebView, navigationDidFinishDocumentLoad navigation: WKNavigation?) {
        guard webView === web else { return }
        firstMeasure()
    }

    /// Measured while still the 25-point square and unseen, then shown at the
    /// size found.
    private func firstMeasure() {
        guard let web, !shown else { return }
        web.evaluateJavaScript("(\(Self.preferred))()") { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self, web === self.web, !self.shown else { return }
                guard let pair = value as? [Double], pair.count == 2 else { return }
                self.apply(NSSize(width: pair[0], height: pair[1]))
            }
        }
    }

    private func apply(_ size: NSSize) {
        guard let popover else { return }
        if abs(size.width - popover.contentSize.width) > 1
            || abs(size.height - popover.contentSize.height) > 1 {
            popover.contentViewController?.preferredContentSize = size
            popover.contentSize = size
            stage?.setFrameSize(size)
            // The web view autoresizes inside the stage; setting its frame
            // too made the popover and the page chase each other.
        }
        if let id = extensionID { Self.lastSize[id] = size }
        reveal()
    }

    /// From the page's first load: sized, then followed as it grows — a
    /// list filled in by a reply from the worker — for as long as it's open.
    private func follow() {
        guard sizing == nil else { return }
        if !shown { firstMeasure() }
        ticks = 0
        sizing = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.grow() }
        }
    }

    /// How far the page reaches, as a function of "width" or "height":
    /// its own width if it names one wider than the view, else its
    /// narrowest (min-content — what is positioned off to the side doesn't
    /// count, as in Chrome's measure), else, for a page that only fills the
    /// view and has next to no width of its own, what its content spans.
    /// Height: all it spans.
    static let reach = """
    ((key) => {
      const d = document.documentElement, v = document.compatMode === "BackCompat" ? document.body : d;
      if (!v) return null;
      if (key === "height") return d.scrollHeight;
      const own = d.getBoundingClientRect().width, gutter = innerWidth - v.clientWidth;
      if (own > v.clientWidth + 1) return own + gutter;
      const saved = d.getAttribute("style");
      d.style.setProperty("width", "min-content", "important");
      const narrowest = d.getBoundingClientRect().width;
      saved === null ? d.removeAttribute("style") : d.setAttribute("style", saved);
      return (narrowest >= 100 ? narrowest : Math.max(narrowest, d.scrollWidth)) + gutter;
    })
    """

    /// Measured again as the page builds itself, the way Chrome measures on
    /// each layout: for its first two seconds the popup follows it either
    /// way, after that it only grows — so a page that settles doesn't set it
    /// rocking.
    private func grow() {
        guard shown, let web, let popover else { return }
        ticks += 1
        if ticks <= 8 {
            web.evaluateJavaScript("(\(Self.preferred))()") { [weak self] value, _ in
                MainActor.assumeIsolated {
                    guard let self, let pair = value as? [Double], pair.count == 2 else { return }
                    let wanted = NSSize(width: pair[0], height: pair[1])
                    let now = popover.contentSize
                    if abs(wanted.width - now.width) > 2 || abs(wanted.height - now.height) > 2 {
                        self.apply(wanted)
                    }
                }
            }
            return
        }
        // After its first two seconds, once a second is enough to follow it;
        // only growth is taken, so a settled page cannot shrink and grow back.
        if ticks > 24, ticks % 4 != 0 { return }
        web.evaluateJavaScript("[\(Self.reach)('width'), \(Self.reach)('height')]") { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self, let pair = value as? [Double], pair.count == 2 else { return }
                let now = popover.contentSize
                // After the first two seconds only growth is taken, so a
                // page that settles cannot shrink and grow back.
                let wanted = NSSize(
                    width: min(800, max(now.width, pair[0].rounded(.up))),
                    height: min(600, max(now.height, pair[1].rounded(.up)))
                )
                if wanted != now { self.apply(wanted) }
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
        stage = nil
        web = nil
        extensionID = nil
        capture = nil
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
        Log.extensions.notice("popup: loaded \(webView.url?.absoluteString ?? "-")")
        follow()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === web else { return }
        Log.extensions.notice("popup: committed \(webView.url?.absoluteString ?? "-")")
    }

    func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
        guard webView === web else { return }
        Log.extensions.error("popup: failed: \(String(describing: error))")
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard webView === web else { return }
        Log.extensions.error("popup: failed to start: \(String(describing: error))")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === web else { return }
        Log.extensions.error("popup: page process ended")
    }

    func webViewDidClose(_ webView: WKWebView) { close() }

    // An extension's own page may ask for the camera, microphone or screen.
    // WebKit still shows the Mac's picker for `getDisplayMedia`; this only
    // allows the request from a page that is the extension's own.
    func webView(
        _ webView: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        .grant
    }

    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func displayCapture(
        _ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo,
        systemAudio: Bool, decisionHandler: @escaping (Int) -> Void
    ) {
        // Only while Chord's own capture call is in flight: the extension
        // cannot raise the Mac's picker on its own.
        decisionHandler(capture?.displayDecision(for: webView) ?? 0)
    }

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
    () => {
      const d = document.documentElement;
      const v = document.compatMode === "BackCompat" ? document.body : d;
      if (!v) return null;
      // What the page measured last time. Re-measuring min-content on every
      // tick makes a responsive popup (Bitwarden) flip between its narrow and
      // wide layouts for ever: half/full/half. The remembered width is used
      // once the page fills the view.
      const m = window.__chordSizing || (window.__chordSizing = {});
      const saved = d.getAttribute("style");
      const back = () => saved === null ? d.removeAttribute("style") : d.setAttribute("style", saved);
      const box = d.getBoundingClientRect();
      let w;
      if (Math.abs(box.width - v.clientWidth) > 1) w = m.w = box.width;
      else if (m.w && Math.abs(m.w - v.clientWidth) <= 1) w = m.w;
      else {
        d.style.setProperty("width", "min-content", "important");
        const narrowest = d.getBoundingClientRect().width;
        back();
        w = narrowest >= 100 ? narrowest : Math.max(narrowest, d.scrollWidth);
      }
      const gutter = innerWidth - v.clientWidth;
      w = Math.min(800, Math.max(25, Math.ceil(w + gutter)));
      d.style.setProperty("width", (w - gutter) + "px", "important");
      let h = d.getBoundingClientRect().height;
      if (Math.abs(h - innerHeight) > 1) m.h = h;
      else if (m.h && Math.abs(m.h - innerHeight) <= 1) h = m.h;
      else {
        d.style.setProperty("height", "auto", "important");
        d.style.setProperty("min-height", "0", "important");
        h = d.getBoundingClientRect().height;
      }
      back();
      return [w, Math.min(600, Math.max(25, Math.ceil(h + innerHeight - v.clientHeight)))];
    }
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
