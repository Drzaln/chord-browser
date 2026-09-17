import AppKit

/// Pure decision for the swipe-to-close experiment, separated so it can be
/// reasoned about without a trackpad.
///
/// A rightward swipe "commits" to closing a pane when the pane could not go
/// back at the *start* of the gesture — the moment WebKit's native back/forward
/// gesture would have decided it had nothing to navigate to.
enum BackSwipeDecision {
    /// How far (in trackpad points) a rightward swipe must travel to count as a
    /// deliberate back gesture rather than a stray horizontal scroll.
    static let commitDistance: CGFloat = 60

    static func commit(dx: CGFloat, dy: CGFloat, couldGoBack: Bool) -> Bool {
        guard !couldGoBack else { return false }
        guard dx > commitDistance else { return false }
        return abs(dx) > abs(dy) * 1.5
    }

    /// A committed no-history swipe belongs to the page — not the tab-close —
    /// when the point under the cursor is over content the page scrolls
    /// horizontally (Google Sheets, wide data tables). WebKit's own back
    /// gesture skips such swipes for the same reason; the monitor mirrors that
    /// decision so a horizontal scroll never closes a tab.
    static func isPageScroll(_ hasHorizontalScroll: Bool) -> Bool {
        hasHorizontalScroll
    }
}

/// Watches the "undo page" swipe — a two-finger rightward trackpad drag — while
/// WebKit's own `allowsBackForwardNavigationGestures` stays on, and reports the
/// swipes that had nothing to undo.
///
/// WebKit gives no callback when its native back/forward gesture fires but
/// `canGoBack` is false; the swipe simply falls through and nothing happens.
/// This monitor watches the same `.scrollWheel` stream and fires
/// `onSwipeRightNoHistory` when a committed rightward swipe ends on a pane that
/// could not go back. Events are observed, never consumed, so the native
/// gesture behaves exactly as before — a pane with history still gets WebKit's
/// interactive back swipe.
///
/// One more gate mirrors WebKit's own: WebKit only treats a rightward swipe as
/// a back gesture when the page under the cursor cannot scroll horizontally
/// (a swipe over Google Sheets or a wide table scrolls the page instead). The
/// monitor asks the page the same question asynchronously, and only closes when
/// the page had no horizontal scroll to consume the gesture.
@MainActor
final class BackSwipeMonitor {
    /// The swipe in flight. One session per gesture, captured at `.began`.
    private struct Session {
        let webView: ChordWebView
        /// Snapshot at `.began`: a pane that *could* go back is left to WebKit,
        /// whose navigation would flip `canGoBack` false mid-swipe and make this
        /// monitor think it should close the tab.
        let couldGoBack: Bool
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        /// The page's answer to "can the point under the cursor scroll
        /// horizontally?", resolved asynchronously. `nil` until it lands.
        var pageScrollsHorizontally: Bool?
    }

    private var session: Session?
    private var monitor: Any?
    /// A committed swipe whose page-scroll answer had not arrived by `.ended`;
    /// fired once the answer says the page had no horizontal scroll to consume.
    private var pendingClose: ChordWebView?

    /// Fired once per committed rightward swipe that ended on a pane with no
    /// back history. The pane's view may already be gone by the time this runs.
    var onSwipeRightNoHistory: ((ChordWebView) -> Void)?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event)
            // Observe, never consume: the native back/forward gesture needs
            // every event, including the ones this monitor acts on.
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        session = nil
        pendingClose = nil
    }

    private func handle(_ event: NSEvent) {
        switch event.phase {
        case .began:
            session = chordView(under: event).map {
                let view = $0
                let new = Session(webView: view, couldGoBack: view.canGoBack)
                probePageScroll(at: event.locationInWindow, in: view)
                return new
            }
            accumulate(event)
        case .changed:
            guard session != nil else { return }
            accumulate(event)
        case .ended:
            guard let session else { return }
            self.session = nil
            guard BackSwipeDecision.commit(
                dx: session.dx, dy: session.dy, couldGoBack: session.couldGoBack
            ) else { return }
            switch session.pageScrollsHorizontally {
            case .some(true):
                // The page consumed the swipe as a horizontal scroll (Sheets).
                return
            case .some(false):
                onSwipeRightNoHistory?(session.webView)
            case nil:
                // The page's answer is still in flight; fire when it lands.
                pendingClose = session.webView
            }
        case .cancelled:
            session = nil
        default:
            // Momentum tail and phaseless mouse-wheel events. The gesture's
            // finger phase is over, so there is nothing left to watch.
            break
        }
    }

    /// Asks the page whether the point under the cursor sits over content that
    /// would consume a rightward swipe as a horizontal scroll. The answer gates
    /// the close decision in `.ended`.
    ///
    /// Mirrors the way Arc behaves: web apps that render into a `<canvas>` and
    /// handle panning themselves — Google Sheets' grid, Figma's canvas — own a
    /// horizontal swipe, so it must not close the tab. Short of that, content
    /// with real horizontal scrollroom takes the swipe: a container that
    /// declares scrollable overflow (`overflow-x: auto/scroll`), or one JS has
    /// scrolled (`scrollLeft > 0`, reachable even under `overflow: hidden`).
    /// Plain overflow-visible elements (a wide `<pre>`, an image, a long URL)
    /// have horizontal overflow but no scrollroom, so they must not suppress
    /// the close.
    private func probePageScroll(at point: NSPoint, in webView: ChordWebView) {
        let zoom = webView.pageZoom
        guard zoom > 0 else { return }
        let local = webView.convert(point, from: nil)
        // `pageZoom` scales content about the top-left corner; divide the local
        // point by it to get CSS viewport coordinates for `elementFromPoint`.
        let x = local.x / zoom
        let y = local.y / zoom
        let script = """
        (() => {
            var stack = document.elementsFromPoint(\(x), \(y));
            if (!stack || !stack.length) { return false; }
            // A canvas anywhere under the cursor is an app-drawn surface
            // (Sheets, Figma) that pans itself; the native gesture has nothing
            // to navigate. `elementsFromPoint` sees past a transparent overlay
            // div sitting above the canvas.
            for (var i = 0; i < stack.length; i++) {
                if (stack[i] && stack[i].tagName === 'CANVAS') { return true; }
            }
            var el = stack[0];
            while (el) {
                if (el.scrollWidth > el.clientWidth) {
                    var ox = getComputedStyle(el).overflowX;
                    var scrollable = (ox === 'auto' || ox === 'scroll' || ox === 'overlay');
                    // The element owns a rightward swipe when it has horizontal
                    // overflow and can put it to use: it declares scrollable
                    // overflow, or JS has already scrolled it (scrollLeft > 0 is
                    // only reachable on a scroll container, even one styled
                    // overflow:hidden — Google Sheets scrolls its grid that way).
                    // A wide element with overflow visible (a pre, an image, a
                    // long URL) has overflow but no scrollroom, so it does not.
                    if (scrollable || el.scrollLeft > 0) { return true; }
                }
                el = el.parentElement;
            }
            return false;
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self else { return }
            let hasHorizontalScroll = (result as? Bool) ?? false
            if self.session?.webView === webView {
                self.session?.pageScrollsHorizontally = hasHorizontalScroll
            }
            if self.pendingClose === webView {
                self.pendingClose = nil
                if BackSwipeDecision.isPageScroll(hasHorizontalScroll) {
                    return
                }
                self.onSwipeRightNoHistory?(webView)
            }
        }
    }

    private func accumulate(_ event: NSEvent) {
        session?.dx += event.scrollingDeltaX
        session?.dy += event.scrollingDeltaY
    }

    /// The `ChordWebView` under the cursor, or nil when the swipe starts over
    /// chrome (sidebar, toolbar) rather than a page.
    private func chordView(under event: NSEvent) -> ChordWebView? {
        guard let window = event.window,
              let hit = window.contentView?.hitTest(event.locationInWindow)
        else { return nil }
        var view: NSView? = hit
        while let current = view {
            if let chord = current as? ChordWebView { return chord }
            view = current.superview
        }
        return nil
    }
}