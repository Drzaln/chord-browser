import AppKit
import SwiftUI

/// A non-activating panel centred over the main window (4.4).
///
/// `NSPanel` rather than a SwiftUI sheet because the bar must take key focus
/// without activating the app or disturbing the window behind it, which no
/// SwiftUI presentation gives us.
final class CommandBarPanel: NSPanel {
    private let session: CommandBarSession

    /// The panel grows and shrinks as results come and go. AppKit keeps the
    /// bottom-left corner fixed on resize, which would walk the bar down the
    /// screen as you type, so the *top* edge is anchored instead.
    private var anchorTopY: CGFloat?
    private var anchorCenterX: CGFloat?

    init(contentViewController: NSViewController, session: CommandBarSession) {
        self.session = session
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 60),
            // .nonactivatingPanel is the point of using NSPanel at all.
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        hidesOnDeactivate = true
        animationBehavior = .utilityWindow

        // Without this a non-activating panel cannot take keyboard input, and
        // the whole bar is unusable.
        becomesKeyOnlyIfNeeded = false

        // A view *controller*, not a bare view: the window follows its
        // preferredContentSize, which is what makes the result list visible at
        // all. A plain NSHostingView with an autoresizing mask resizes with the
        // window rather than driving it, so the list rendered inside a 60 pt
        // window and was clipped away entirely.
        self.contentViewController = contentViewController
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    /// `NSPanel` refuses key status by default for non-activating panels.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc dismisses (4.4).
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    /// Cmd+Enter forces a new tab (4.4).
    ///
    /// It has to be caught here, before SwiftUI: a focused `TextField` consumes
    /// Return for its own submit and ignores it outright when Command is held,
    /// so neither `onSubmit`, `onKeyPress`, nor a `.keyboardShortcut` inside the
    /// view ever sees the event.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isReturn = event.charactersIgnoringModifiers == "\r"
            || event.keyCode == 36
            || event.keyCode == 76  // numeric keypad enter

        if isReturn, event.modifierFlags.contains(.command) {
            session.requestActivate(forceNewTab: true)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Keeps the top edge and horizontal centre fixed through every resize.
    ///
    /// The panel is re-laid-out whenever the result count changes, and AppKit
    /// preserves the origin (bottom-left), so without this the bar visibly
    /// crawls upward as results appear.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if let anchorTopY { rect.origin.y = anchorTopY - rect.height }
        if let anchorCenterX { rect.origin.x = anchorCenterX - rect.width / 2 }
        super.setFrame(rect, display: flag)
    }

    func present(over parent: NSWindow?) {
        let reference = parent?.frame ?? NSScreen.main?.visibleFrame

        if let reference {
            // Centred horizontally, biased toward the top third — where the eye
            // already is, and clear of the content below.
            anchorCenterX = reference.midX
            anchorTopY = reference.midY + reference.height / 6
            setFrame(frame, display: false)
        } else {
            anchorCenterX = nil
            anchorTopY = nil
            center()
        }

        makeKeyAndOrderFront(nil)
    }
}
