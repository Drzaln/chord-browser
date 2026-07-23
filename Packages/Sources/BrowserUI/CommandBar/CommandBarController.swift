import AppKit
import BrowserStore
import SwiftUI

/// Owns the command bar panel and its lifetime.
///
/// The panel is built once and reused. Rebuilding it per invocation would blow
/// the 50 ms open-to-input-ready budget in 6.1 on view construction alone.
@MainActor
public final class CommandBarController {
    private let store: TabStore
    private let session = CommandBarSession()
    private var panel: CommandBarPanel?

    public init(store: TabStore) {
        self.store = store
    }

    public var isVisible: Bool { panel?.isVisible ?? false }

    public func toggle(over parent: NSWindow?) {
        isVisible ? dismiss() : present(over: parent)
    }

    public func present(over parent: NSWindow?) {
        let panel = existingOrNewPanel()

        // History and archive are refreshed here, once, rather than on every
        // keystroke — typing must never touch the disk (6.1).
        Task { await store.prepareCommandBar() }

        panel.present(over: parent)

        // After the panel is key, so the text field can actually become first
        // responder.
        session.beginPresentation()

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

        let hosting = NSHostingView(
            rootView: CommandBarView(
                store: store,
                session: session,
                dismiss: { [weak self] in self?.dismiss() }
            )
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 60)

        // The panel resizes to whatever the result list needs.
        hosting.autoresizingMask = [.width, .height]

        let panel = CommandBarPanel(contentView: hosting, session: session)
        self.panel = panel
        return panel
    }
}
