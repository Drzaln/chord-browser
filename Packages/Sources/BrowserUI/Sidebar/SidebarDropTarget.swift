import AppKit
import SwiftUI

/// A drag *destination* for the sidebar, beside the `TabDragSource` the row
/// already is (4.1). Reused for the three drop regions: the ephemeral list, the
/// favourites grid, and each Space button.
///
/// AppKit rather than SwiftUI `.onDrop`, to stay on one mechanism with the drag
/// source and the split drop target — the payload is an `NSPasteboardItem`
/// written by `TabDragSource`, and reading it through the same pasteboard the
/// source wrote avoids the empty-`NSItemProvider` trap that pushed both the
/// source and the split target to AppKit in the first place (see "How
/// drag-to-split works").
///
/// Coordinates are reported top-left, matching SwiftUI, so a caller can turn a
/// drop location into an insertion index directly.
struct SidebarDropTarget: NSViewRepresentable {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    /// Cursor location (top-left origin) on each `draggingUpdated`.
    var onUpdate: (CGPoint) -> Void = { _ in }
    /// The dragged tab and where in the target it was released.
    let onDrop: (UUID, CGPoint) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = DropView()
        view.registerForDraggedTypes([.browserTab])
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? DropView else { return }
        apply(to: view)
    }

    private func apply(to view: DropView) {
        view.onEnter = onEnter
        view.onExit = onExit
        view.onUpdate = onUpdate
        view.onDrop = onDrop
    }

    final class DropView: NSView {
        var onEnter: (() -> Void)?
        var onExit: (() -> Void)?
        var onUpdate: ((CGPoint) -> Void)?
        var onDrop: ((UUID, CGPoint) -> Void)?

        /// Top-left origin, so a drop location maps straight onto SwiftUI layout.
        override var isFlipped: Bool { true }

        private func location(_ sender: NSDraggingInfo) -> CGPoint {
            convert(sender.draggingLocation, from: nil)
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            onEnter?()
            onUpdate?(location(sender))
            return operation(for: sender)
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            onUpdate?(location(sender))
            return operation(for: sender)
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            onExit?()
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            onExit?()
        }

        /// Must be an operation the source offers, or AppKit refuses the drop —
        /// the same rule the split target learned. `TabDragSource` offers `.move`.
        private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
            sender.draggingSourceOperationMask.contains(.move) ? .move : []
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            onExit?()
            let board = sender.draggingPasteboard
            let payload = board.data(forType: .browserTab)
                ?? board.pasteboardItems?.compactMap { $0.data(forType: .browserTab) }.first
            guard let payload, let tabID = TabDragPayload.tabID(from: payload) else {
                return false
            }
            onDrop?(tabID, location(sender))
            return true
        }
    }
}
