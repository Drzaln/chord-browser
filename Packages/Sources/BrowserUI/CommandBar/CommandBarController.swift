import AppKit
import BrowserStore
import SwiftUI
import os

/// Owns the command bar panel and its lifetime.
///
/// The panel is built once and reused. Rebuilding it per invocation would blow
/// the 50 ms open-to-input-ready budget in 6.1 on view construction alone.
@MainActor
public final class CommandBarController {
    /// The 50 ms budget in 6.1 is too tight to measure from outside the process
    /// — an accessibility probe costs more than the budget itself — so the
    /// interval is recorded here instead.
    private static let signposter = OSSignposter(
        subsystem: "com.rizal.browser", category: "lifecycle"
    )

    private static let width: CGFloat = 640

    private let store: TabStore
    private let session = CommandBarSession()
    private var panel: CommandBarPanel?

    /// The window the bar is currently acting for. The panel is built once and
    /// reused across windows, so what it targets has to be swapped per
    /// presentation rather than baked into the view — otherwise a bar opened
    /// from the second window would still open tabs in the first.
    private let target = CommandBarTarget()

    public init(store: TabStore) {
        self.store = store
    }

    public var isVisible: Bool { panel?.isVisible ?? false }

    public func toggle(
        over parent: NSWindow?,
        windowState: WindowState?,
        mode: CommandBarMode = .newTab
    ) {
        isVisible ? dismiss() : present(over: parent, windowState: windowState, mode: mode)
    }

    public func present(
        over parent: NSWindow?,
        windowState: WindowState?,
        mode: CommandBarMode = .newTab,
        initialQuery: String = ""
    ) {
        // Whichever window asked. Nil means no browser window is focused, in
        // which case the bar falls back to the primary rather than doing nothing.
        target.windowState = windowState ?? store.primaryWindow
        // Bounds the app-side work only: panel on screen and routed to first
        // responder. It does not include the compositor putting the frame on
        // the display.
        let interval = Self.signposter.beginInterval("commandBarOpen")
        defer { Self.signposter.endInterval("commandBarOpen", interval) }

        let panel = existingOrNewPanel()

        // History and archive are refreshed here, once, rather than on every
        // keystroke — typing must never touch the disk (6.1).
        Task { await store.prepareCommandBar() }

        panel.present(over: parent)

        // After the panel is key, so the text field can actually become first
        // responder.
        session.beginPresentation(mode: mode, initialQuery: initialQuery)

        // NSHostingView does not always accept first responder on its own; ask
        // the panel to route keyboard input into it explicitly.
        if let content = panel.contentView {
            panel.makeFirstResponder(content)
        }
    }

    public func dismiss() {
        panel?.orderOut(nil)
    }

    private func existingOrNewPanel() -> CommandBarPanel {
        if let panel { return panel }

        let hosting = NSHostingController(
            rootView: CommandBarView(
                store: store,
                target: target,
                session: session,
                dismiss: { [weak self] in self?.dismiss() }
            )
            .frame(width: Self.width)
        )

        // The panel takes its height from the content, so the result list is
        // actually on screen. Width is fixed by the view above.
        hosting.sizingOptions = [.preferredContentSize]

        let panel = CommandBarPanel(contentViewController: hosting, session: session)
        self.panel = panel
        return panel
    }
}
