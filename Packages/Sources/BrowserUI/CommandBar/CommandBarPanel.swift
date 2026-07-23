import AppKit
import SwiftUI

/// A non-activating panel centred over the main window (4.4).
///
/// `NSPanel` rather than a SwiftUI sheet because the bar must take key focus
/// without activating the app or disturbing the window behind it, which no
/// SwiftUI presentation gives us.
final class CommandBarPanel: NSPanel {
    private let session: CommandBarSession

    init(contentView: NSView, session: CommandBarSession) {
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

        self.contentView = contentView
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

    func present(over parent: NSWindow?) {
        if let parent {
            let parentFrame = parent.frame
            let size = frame.size
            // Centred horizontally, biased toward the top third — where the eye
            // already is, and clear of the content below.
            let origin = NSPoint(
                x: parentFrame.midX - size.width / 2,
                y: parentFrame.midY + parentFrame.height / 6
            )
            setFrameOrigin(origin)
        } else {
            center()
        }

        makeKeyAndOrderFront(nil)
    }
}
