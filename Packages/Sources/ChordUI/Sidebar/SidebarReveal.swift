import AppKit
import SwiftUI

/// A strip down the window's left edge that reveals the hidden sidebar when
/// the pointer reaches it (4.1).
///
/// A collapsed sidebar occupies no space at all, so there is no view left to
/// attach `onHover` to, and the strip that replaces it sits directly over the
/// web view. Two approaches were tried and rejected before this one:
///
/// - A SwiftUI overlay with `onHover`. It swallows clicks meant for the page,
///   and `allowsHitTesting(false)` — the obvious fix — also stops the hover.
///   The same trap the M5 drop target hit.
/// - A `mouseMoved` local monitor. AppKit does not deliver mouseMoved unless a
///   window opts in, and even then it did not fire here.
///
/// An `NSTrackingArea` has neither problem: it reports enter and exit
/// regardless of hit testing, so `hitTest` can return nil and let every click
/// through to the page underneath while the strip still sees the pointer.
struct SidebarRevealStrip: NSViewRepresentable {
    /// How close to the edge counts as reaching for the sidebar. A couple of
    /// points is a coin toss to hit deliberately; much more and the sidebar
    /// appears while you are aiming at something else near the edge.
    static let width: CGFloat = 6

    let onEnter: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = StripView()
        view.onEnter = onEnter
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? StripView)?.onEnter = onEnter
    }

    final class StripView: NSView {
        var onEnter: (() -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero,
                    // `.inVisibleRect` keeps the area correct as the window
                    // resizes without recomputing it by hand. `.activeAlways`
                    // so the edge works before the app is focused, which is
                    // exactly when you reach for a hidden sidebar.
                    options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                    owner: self,
                    userInfo: nil
                )
            )
        }

        override func mouseEntered(with event: NSEvent) {
            onEnter?()
        }

        /// Invisible to clicks. The strip lies over the web view, and a page is
        /// not usable if its leftmost few points swallow every click. Tracking
        /// areas fire regardless of hit testing, which is the whole reason this
        /// works.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
