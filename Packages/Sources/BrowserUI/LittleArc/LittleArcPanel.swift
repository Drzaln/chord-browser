import AppKit

/// The floating panel a link from another app opens in (4.6).
///
/// Borderless and independent of the main window — it may appear when no main
/// window exists at all, which is why it is a panel the app owns directly
/// rather than anything hung off `RootView`.
final class LittleArcPanel: NSPanel {
    static let defaultSize = NSSize(width: 720, height: 560)
    static let minimumSize = NSSize(width: 420, height: 320)

    /// Called for Esc and for `Cmd+O`, which promotes the page into a real tab.
    var onDismiss: (() -> Void)?
    var onPromote: (() -> Void)?

    init(contentViewController: NSViewController) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            // Borderless per 4.6. `.nonactivatingPanel` so opening a link does
            // not yank focus away from whatever app you were in.
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        self.contentViewController = contentViewController
        // Assigning a contentViewController makes the window adopt that
        // controller's *fitting* size, and a web surface has no intrinsic
        // height — the panel collapses to its header (about 105x37) unless the
        // size is restated here, after the assignment.
        setContentSize(Self.defaultSize)
        contentMinSize = Self.minimumSize

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        animationBehavior = .none  // the scale-and-fade below replaces it
        // Survives the main window closing, and follows you across Spaces.
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        becomesKeyOnlyIfNeeded = false
    }

    /// Borderless panels refuse key status by default, and the panel has to take
    /// keys for Esc and Cmd+O to work at all.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Cmd+O promotes (4.6). Caught here rather than in a menu item: the
        // panel is independent of the main window, and may be the only window
        // there is.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "o" {
            onPromote?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
