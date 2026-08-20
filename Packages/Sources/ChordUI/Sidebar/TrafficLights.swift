import AppKit
import SwiftUI

/// Hides the window's close/minimise/zoom buttons while the sidebar is
/// collapsed (4.1).
///
/// They are positioned by AppKit at a fixed offset from the window's top-left
/// and do not care what is under them: in a 48-point rail the zoom button lands
/// on the web content. Widening the rail to fit three buttons would make the
/// collapsed state wider than the thing it collapses for.
///
/// They come back whenever the sidebar is full width, including a hover-expand,
/// so the only state without them is one the pointer is a few points away from
/// leaving.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // `window` is nil until the view is in the hierarchy, which is after
        // `makeNSView` returns — hence the hop rather than reading it here.
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}

extension NSWindow {
    func setTrafficLightsHidden(_ hidden: Bool) {
        for button in [.closeButton, .miniaturizeButton, .zoomButton] as [NSWindow.ButtonType] {
            standardWindowButton(button)?.isHidden = hidden
        }
    }
}
