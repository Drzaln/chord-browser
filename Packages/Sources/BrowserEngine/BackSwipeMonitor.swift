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
    }

    private var session: Session?
    private var monitor: Any?

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
    }

    private func handle(_ event: NSEvent) {
        switch event.phase {
        case .began:
            session = chordView(under: event).map {
                Session(webView: $0, couldGoBack: $0.canGoBack)
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
            onSwipeRightNoHistory?(session.webView)
        case .cancelled:
            session = nil
        default:
            // Momentum tail and phaseless mouse-wheel events. The gesture's
            // finger phase is over, so there is nothing left to watch.
            break
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
