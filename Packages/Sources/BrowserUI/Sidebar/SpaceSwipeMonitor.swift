import AppKit
import BrowserCore
import BrowserStore
import SwiftUI

/// The two-finger horizontal swipe that switches Spaces (4.2).
///
/// Raw scroll-phase `NSEvent` handling, deliberately not an
/// `NSGestureRecognizer`: a recogniser reports a discrete swipe after the fact
/// and cannot drive animation progress continuously, which is the entire feel
/// being copied. A local event monitor sees `.scrollWheel` before any view
/// dispatch, so it can consume a swipe the `WKWebView` would otherwise scroll.
///
/// It engages only when a gesture *begins* clearly horizontal and carries a real
/// trackpad phase. A mouse wheel has no phase, and a vertical scroll should
/// reach the page — so both pass straight through, and page content that
/// genuinely scrolls sideways is only hijacked by a swipe that starts more
/// horizontal than vertical. That ambiguity is inherent to the gesture; Arc
/// resolves it the same way.
@MainActor
final class SpaceSwipeMonitor {
    private let store: TabStore
    private var monitor: Any?

    /// True between a horizontal `.began` and its `.ended`. While false, every
    /// event passes through untouched.
    private var engaged = false
    private var accumulated: Double = 0

    /// The x (in window coordinates, from the left edge) below which a swipe is
    /// over the sidebar and may switch Spaces. Zero disables the gesture — set
    /// while the sidebar is hidden. Kept updated by `RootView` as the sidebar's
    /// width and visibility change.
    ///
    /// This is the fix for the back/forward collision: a horizontal swipe over
    /// the *web content* must reach `WKWebView`'s own navigation gesture, so the
    /// Space switch only claims swipes that start over the sidebar.
    var engageMaxX: CGFloat = 0

    /// The main window. A swipe in any other window (the command bar panel, say)
    /// is never a Space switch.
    weak var window: NSWindow?

    init(store: TabStore) {
        self.store = store
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Returns true when the event was consumed (the swipe owns it) and must not
    /// reach a view.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.phase {
        case .began:
            // Only over the sidebar. A swipe that begins over the web content is
            // left alone so `WKWebView`'s back/forward navigation gesture gets
            // it — the two gestures are the same shape and would otherwise fight.
            guard engageMaxX > 0, event.locationInWindow.x <= engageMaxX else {
                return false
            }
            // ...and only in the main window, not a floating panel.
            if let window, let eventWindow = event.window, eventWindow !== window {
                return false
            }
            // Only a clearly-horizontal trackpad swipe drives a Space switch;
            // anything else is left for the sidebar list to scroll.
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
                return false
            }
            engaged = true
            accumulated = 0
            store.beginSpaceSwipe()
            accumulated += Double(event.scrollingDeltaX)
            store.updateSpaceSwipe(offset: -accumulated)
            return true

        case .changed:
            guard engaged else { return false }
            accumulated += Double(event.scrollingDeltaX)
            // Swipe the fingers left (`scrollingDeltaX < 0`) to move to the next
            // Space, so the offset the store sees is the negated travel.
            store.updateSpaceSwipe(offset: -accumulated)
            return true

        case .ended, .cancelled:
            guard engaged else { return false }
            engaged = false
            release()
            return true

        default:
            // Momentum tail and phaseless mouse-wheel events. Once the swipe has
            // ended there is nothing to consume, so let them through.
            return false
        }
    }

    /// Hand off to a spring: to the neighbour if the swipe committed, back to
    /// rest otherwise. Reduce Motion collapses the spring to a near-instant
    /// cross-fade rather than dropping the transition entirely.
    private func release() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animation = Motion.respectingReduceMotion(
            Motion.spaceSwitch, reduceMotion: reduceMotion
        )

        if store.swipeShouldCommit {
            let direction = store.spaceSwipeProgress >= 0 ? 1 : -1
            withAnimation(animation) {
                // Carry the gradient the rest of the way to the neighbour's
                // stops; committing there is a no-op on the pixels.
                store.setSpaceSwipeProgress(Double(direction))
            } completion: {
                self.store.commitSpaceSwipe(direction: direction)
            }
        } else {
            withAnimation(animation) {
                store.setSpaceSwipeProgress(0)
            }
        }
    }
}
