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
    public func present(url: URL) {
        dismiss()

        let pane = store.makeLittleArcPane(url: url)
        self.pane = pane

        let hosting = NSHostingController(
            rootView: LittleArcView(
                store: store,
                pane: pane,
                promote: { [weak self] in self?.promote() },
                dismiss: { [weak self] in self?.dismiss() }
            )
        )

        let panel = LittleArcPanel(contentViewController: hosting)
        panel.onDismiss = { [weak self] in self?.dismiss() }
        panel.onPromote = { [weak self] in self?.promote() }
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
        store.promoteLittleArc(pane)

        closePanel()

        // Bring the main window forward, since the tab now lives there.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0 is LittleArcPanel == false && $0.canBecomeMain }?
            .makeKeyAndOrderFront(nil)
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
