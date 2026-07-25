import AppKit
import BrowserCore
import BrowserStore
import SwiftUI

/// Owns the ⌘-hover Peek preview panel and its lifetime (non-spec:
/// user-requested).
///
/// One preview at a time: hovering a different link replaces the current pane
/// rather than stacking panels. The preview page is an ordinary Little Arc pane
/// — not in any tab, using the active Space's data store — so a preview arrives
/// already logged in, and is torn down the moment the preview is dismissed.
@MainActor
public final class PeekController {
    private let store: TabStore
    private var panel: PeekPanel?
    private var pane: Pane?
    private var currentURL: URL?

    public init(store: TabStore) {
        self.store = store
    }

    /// Shows a preview of `url`, or dismisses when `nil`. Re-showing the same URL
    /// is a no-op so a steady hover does not rebuild the web view.
    public func present(url: URL?) {
        guard let url else { dismiss(); return }
        guard url != currentURL else { return }

        dismiss()
        currentURL = url

        let pane = store.makeLittleArcPane(url: url)
        self.pane = pane

        let hosting = NSHostingController(rootView: PeekView(store: store, pane: pane))
        let panel = PeekPanel(contentViewController: hosting)
        self.panel = panel

        position(panel)
        // orderFrontRegardless, not makeKey: the preview must never steal focus
        // from the page whose hover is driving it.
        panel.orderFrontRegardless()
    }

    public func dismiss() {
        currentURL = nil
        if let pane {
            store.discardLittleArc(pane)
            self.pane = nil
        }
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        panel = nil
    }

    /// Below-right of the cursor, nudged to stay fully on its screen. Offset so
    /// the panel never sits under the pointer, which would end the hover.
    private func position(_ panel: PeekPanel) {
        let cursor = NSEvent.mouseLocation
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main

        var origin = NSPoint(x: cursor.x + 16, y: cursor.y - size.height - 16)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
    }
}
