import AppKit
import BrowserCore
import BrowserStore
import SwiftUI

/// Owns the Little Arc panel and its lifetime (4.6).
///
/// One panel at a time: a second link replaces the first rather than stacking
/// panels, which is what makes this feel like a peek rather than a window
/// manager.
@MainActor
public final class LittleArcController {
    private let store: TabStore
    private var panel: LittleArcPanel?
    private var pane: Pane?

    public init(store: TabStore) {
        self.store = store
    }

    public var isVisible: Bool { panel?.isVisible ?? false }

    /// Opens `url` in the panel, scaling and fading in from the cursor (4.6).
    ///
    /// `spaceID` picks which Space's data store the page uses, so a preview
    /// arriving from a click in a favourite is already logged in to that
    /// favourite's Space. `nil` means the primary window's active Space — the
    /// Little Arc path.
    public func present(url: URL, inSpace spaceID: UUID? = nil) {
        dismiss()

        let pane = store.makeLittleArcPane(url: url)
        self.pane = pane

        let hosting = NSHostingController(
            rootView: LittleArcView(
                store: store,
                pane: pane,
                spaceID: spaceID,
                promote: { [weak self] in self?.promote() },
                dismiss: { [weak self] in self?.dismiss() }
            )
        )

        let panel = LittleArcPanel(contentViewController: hosting, size: store.littleArcPanelSize)
        panel.onDismiss = { [weak self] in self?.dismiss() }
        panel.onPromote = { [weak self] in self?.promote() }
        // The size the user just dragged the panel to is what the next panel
        // should open at (non-spec: user-requested).
        panel.onResize = { [weak self] size in self?.store.littleArcPanelSize = size }
        self.panel = panel

        position(panel)
        animateIn(panel)
    }

    /// `Cmd+O` — becomes a real tab in the active Space, and the panel goes away.
    public func promote() {
        guard let pane else { return }
        // Clear the pane first: dismiss() would otherwise tear down the web view
        // we are about to hand over.
        self.pane = nil
        // The window the user last focused, not always the primary: the panel
        // itself never registers as focused (it is not a browser scene), so the
        // store's `focusedWindow` still names the browser window that was current
        // when the link arrived. A URL opened at a cold launch has no focused
        // window and falls back to the primary.
        let target = store.focusedNonPrivateWindow
        store.promoteLittleArc(pane, in: target)

        closePanel()

        // Bring that same window forward, since the tab now lives there — falling
        // back to any main-capable window if its NSWindow is somehow gone.
        NSApp.activate(ignoringOtherApps: true)
        let front = WindowRegistry.nsWindow(for: target)
            ?? NSApp.windows.first { $0 is LittleArcPanel == false && $0.canBecomeMain }
        front?.makeKeyAndOrderFront(nil)
    }

    public func dismiss() {
        if let pane {
            // Nothing else refers to this pane, so its web view has to go
            // explicitly or it lives as long as the app does.
            store.discardLittleArc(pane)
            self.pane = nil
        }
        closePanel()
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        panel = nil
    }

    // MARK: - Placement and animation

    /// Centred on the cursor, then nudged to stay fully on its screen.
    private func position(_ panel: LittleArcPanel) {
        let cursor = NSEvent.mouseLocation
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) }
            ?? NSScreen.main

        var origin = NSPoint(x: cursor.x - size.width / 2, y: cursor.y - size.height / 2)

        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 12), visible.maxX - size.width - 12)
            origin.y = min(max(origin.y, visible.minY + 12), visible.maxY - size.height - 12)
        }
        panel.setFrameOrigin(origin)
    }

    /// Scale-and-fade in from the cursor (4.6), honouring Reduce Motion.
    private func animateIn(_ panel: LittleArcPanel) {
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = 1
            return
        }

        let final = panel.frame
        // Start small, centred on the same point, so it grows out of the cursor
        // rather than sliding in from a corner.
        let scale = Motion.littleArcEntryScale
        let start = NSRect(
            x: final.midX - final.width * scale / 2,
            y: final.midY - final.height * scale / 2,
            width: final.width * scale,
            height: final.height * scale
        )
        panel.setFrame(start, display: false)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.littleArcEntryDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(final, display: true)
            panel.animator().alphaValue = 1
        }
    }
}
