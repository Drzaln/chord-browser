import AppKit

/// The floating preview panel for ⌘-hover Peek (non-spec: user-requested).
///
/// Deliberately inert: it never takes focus or the mouse, so hovering it does
/// not interrupt the page's `mousemove` stream that drives Peek — releasing ⌘
/// still dismisses it. It is a glance, not a window you interact with.
final class PeekPanel: NSPanel {
    static let size = NSSize(width: 420, height: 300)

    init(contentViewController: NSViewController) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.contentViewController = contentViewController
        setContentSize(Self.size)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        animationBehavior = .utilityWindow
        ignoresMouseEvents = true
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .transient]
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
