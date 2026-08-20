import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Makes a sidebar row an AppKit drag *source*, for dragging a tab into the
/// content area to split it (4.5).
///
/// SwiftUI's `onDrag` cannot do this job. Its `NSItemProvider` reaches the
/// destination with the type advertised on the dragging pasteboard but the
/// payload **zero bytes long** — `data(forType:)` returns empty `Data`, not
/// nil, whether read from the pasteboard or from `pasteboardItems`. A lazy
/// `registerDataRepresentation` and an eager
/// `NSItemProvider(item:typeIdentifier:)` both do it. Owning both ends of the
/// drag — an `NSPasteboardItem` written here, read by `TabDropTarget` — is what
/// finally puts real bytes on the pasteboard.
///
/// It also fixes the operation mask. `onDrag` advertises `.copy`, and a
/// destination must return an operation the source offers, so the move that
/// 4.5 actually specifies was not expressible from the SwiftUI side.
struct TabDragSource: NSViewRepresentable {
    let tabID: UUID
    let title: String
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void
    let onClick: () -> Void
    /// Fired on a double-click, when set. Used by favourite tiles to return the
    /// tab to its home URL (4.1).
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = DragSourceView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? DragSourceView else { return }
        apply(to: view)
    }

    private func apply(to view: DragSourceView) {
        view.tabID = tabID
        view.title = title
        view.onDragBegan = onDragBegan
        view.onDragEnded = onDragEnded
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
    }

    final class DragSourceView: NSView, NSDraggingSource {
        var tabID: UUID?
        var title: String = ""
        var onDragBegan: (() -> Void)?
        var onDragEnded: (() -> Void)?
        var onClick: (() -> Void)?
        var onDoubleClick: (() -> Void)?

        /// The mouse-down that a drag session must be started from: AppKit
        /// tracks the drag against that event, not against the one that crossed
        /// the threshold.
        private var mouseDownEvent: NSEvent?
        private var isDragging = false

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
            isDragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !isDragging, let mouseDownEvent, let tabID else { return }

            // A few points of slop, so a sloppy click on a row selects it
            // rather than starting a drag nobody asked for.
            let start = convert(mouseDownEvent.locationInWindow, from: nil)
            let now = convert(event.locationInWindow, from: nil)
            guard hypot(now.x - start.x, now.y - start.y) > 3 else { return }

            isDragging = true

            let item = NSPasteboardItem()
            item.setData(TabDragPayload.data(for: tabID), forType: .browserTab)

            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            draggingItem.setDraggingFrame(bounds, contents: dragImage())

            onDragBegan?()
            beginDraggingSession(with: [draggingItem], event: mouseDownEvent, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            mouseDownEvent = nil
            // Selects the row. This lives here rather than in a SwiftUI
            // `onTapGesture` because this view sits above the row and would
            // otherwise swallow the click.
            //
            // `isDragging` is cleared by the *next* `mouseDown`, never here and
            // never when the session ends. A drag mostly consumes its own
            // mouse-up, but not always: clearing the flag from
            // `draggingSession(_:endedAt:operation:)` let a mouse-up that did
            // arrive afterwards read as a plain click, so ending any drag also
            // selected the row that had just been dragged — visible as a
            // refused drop that moved the selection anyway.
            if !isDragging {
                // A double-click on a favourite returns it home; a single click
                // selects. `clickCount` is 2 on the second mouse-up of a pair,
                // so the first still fires `onClick` — selecting then returning
                // home reads correctly for a favourite.
                if event.clickCount == 2, let onDoubleClick {
                    onDoubleClick()
                } else {
                    onClick?()
                }
            }
        }

        // MARK: - NSDraggingSource

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            // A tab means nothing outside this app, so nothing is offered
            // outside it. Within it the tab is *moved* (4.5) — it stops being
            // its own row.
            switch context {
            case .withinApplication: return .move
            default: return []
            }
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            // Fires whatever the outcome, including a cancelled drag. The drop
            // layer over the web view is mounted for the duration of the drag
            // and would go on eating clicks if this were missed.
            onDragEnded?()
        }

        // MARK: - Drag image

        /// The row's title on a translucent chip. Snapshotting the row itself
        /// would mean rendering a SwiftUI view from AppKit at drag start, on
        /// the main thread, in the frame the drag has to begin in.
        private func dragImage() -> NSImage {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor,
            ]
            let text = NSAttributedString(string: title, attributes: attributes)
            let size = bounds.size

            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.controlBackgroundColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 6, yRadius: 6)
                .fill()
            let textSize = text.size()
            text.draw(at: NSPoint(x: 8, y: (size.height - textSize.height) / 2))
            image.unlockFocus()
            return image
        }
    }
}
