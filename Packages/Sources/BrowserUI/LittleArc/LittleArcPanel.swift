import AppKit

/// The floating panel a link from another app opens in (4.6).
///
/// Borderless and independent of the main window — it may appear when no main
/// window exists at all, which is why it is a panel the app owns directly
/// rather than anything hung off `RootView`.
final class LittleArcPanel: NSPanel {
    static let defaultSize = NSSize(width: 720, height: 560)
    static let minimumSize = NSSize(width: 560, height: 400)

    /// Called for Esc and for `Cmd+O`, which promotes the page into a real tab.
    var onDismiss: (() -> Void)?
    var onPromote: (() -> Void)?

    /// Called when the user finishes dragging the panel to a new size, so the
    /// controller can remember it for next time.
    var onResize: ((NSSize) -> Void)?

    init(contentViewController: NSViewController, size: NSSize? = nil) {
        // Clamp a remembered size to the minimum: a stale value (or one saved
        // by an earlier buggy build that persisted animation frames) must not
        // be able to shrink the panel below what is usable.
        let saved = size ?? Self.defaultSize
        let initial = NSSize(
            width: max(saved.width, Self.minimumSize.width),
            height: max(saved.height, Self.minimumSize.height)
        )
        super.init(
            contentRect: NSRect(origin: .zero, size: initial),
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
        setContentSize(initial)
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didEndLiveResize(_:)),
            name: NSWindow.didEndLiveResizeNotification,
            object: self
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func didEndLiveResize(_ notification: Notification) {
        // `didEndLiveResize` fires only when the user finishes dragging the
        // panel, never during the programmatic scale-and-fade entry animation —
        // listening on `didResize` instead would persist each animation frame
        // and shrink the panel a little on every open.
        onResize?(frame.size)
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
