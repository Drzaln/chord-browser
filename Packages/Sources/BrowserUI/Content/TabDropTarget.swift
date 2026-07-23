import AppKit
import SwiftUI
import os
import UniformTypeIdentifiers

/// An AppKit drag destination laid over a pane, for dropping a sidebar tab in
/// to split it (4.5).
///
/// SwiftUI's `onDrop` cannot do this job here. AppKit resolves a drop by finding
/// the *deepest* view under the cursor that is registered for the dragged type,
/// and `WKWebView` registers for dragged types itself — so it always wins over a
/// destination SwiftUI installs on the hosting view, and the drop is delivered
/// to the page instead of to us.
///
/// Mounted only while a tab is actually being dragged. A permanent view here
/// would sit above the web view and swallow ordinary clicks.
struct TabDropTarget: NSViewRepresentable {
    let isTargeted: (Bool) -> Void
    let onDrop: (UUID) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = DropView()
        view.isTargeted = isTargeted
        view.onDrop = onDrop
        view.registerForDraggedTypes([.browserTab])
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? DropView else { return }
        view.isTargeted = isTargeted
        view.onDrop = onDrop
    }

    final class DropView: NSView {
        private static let log = Logger(subsystem: "com.rizal.browser", category: "drop")
        var isTargeted: ((Bool) -> Void)?
        var onDrop: ((UUID) -> Void)?

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            isTargeted?(true)
            return operation(for: sender)
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            operation(for: sender)
        }

        /// Must be an operation the *source* actually offers.
        ///
        /// We move the tab, but SwiftUI's `onDrag` advertises the drag as a copy.
        /// Returning `.move` regardless makes AppKit refuse the drop outright:
        /// the highlight appears on hover and then nothing happens on release.
        private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
            let offered = sender.draggingSourceOperationMask
            if offered.contains(.move) { return .move }
            if offered.contains(.copy) { return .copy }
            if offered.contains(.generic) { return .generic }
            return offered.isEmpty ? .generic : offered
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            isTargeted?(false)
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            isTargeted?(false)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            isTargeted?(false)
            let board = sender.draggingPasteboard
            let payload = board.data(forType: .browserTab)
                ?? board.pasteboardItems?.compactMap { $0.data(forType: .browserTab) }.first

            guard let payload,
                  let text = String(data: payload, encoding: .utf8),
                  let tabID = UUID(uuidString: text)
            else {
                // Known broken: the payload arrives as *zero bytes*. See
                // CHECKPOINT, "drag a tab into a split".
                Self.log.error(
                    "drop payload empty (\(payload?.count ?? -1, privacy: .public) bytes)"
                )
                return false
            }

            onDrop?(tabID)
            return true
        }
    }
}

extension NSPasteboard.PasteboardType {
    static let browserTab = NSPasteboard.PasteboardType(UTType.browserTab.identifier)
}
