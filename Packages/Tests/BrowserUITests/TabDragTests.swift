import AppKit
import Testing

@testable import BrowserUI

/// Dragging a sidebar tab into the content area to split it (4.5).
///
/// **These do not cover the bug that held drag-to-split up for a milestone.**
/// That one was `NSItemProvider` arriving at the destination with the type
/// advertised and *zero bytes* behind it, which only happens inside a live
/// AppKit drag session driven by SwiftUI's `onDrag` — there is no way to stage
/// it from a test, and a test written to it would pass against the bug. It was
/// found, and the fix verified, by driving the real app (see SMOKE.md).
///
/// What is worth pinning down here is the part that a test *can* fail on: the
/// two ends of the drag agreeing on a format, and the drop refusing anything
/// that is not one of ours.
@MainActor
@Suite("Tab drag payload")
struct TabDragTests {

    @Test("What the source writes is what the destination reads")
    func roundTripsThroughARealPasteboard() throws {
        let tabID = UUID()

        // Written exactly as `TabDragSource` writes it, onto a real pasteboard
        // rather than a stub, so a type that AppKit refuses to carry fails here.
        let item = NSPasteboardItem()
        item.setData(TabDragPayload.data(for: tabID), forType: .browserTab)

        let board = NSPasteboard(name: .init(rawValue: "com.rizal.browser.tests.\(tabID)"))
        board.clearContents()
        board.writeObjects([item])

        // Read exactly as `TabDropTarget` reads it.
        let payload = try #require(board.data(forType: .browserTab))
        #expect(payload.isEmpty == false, "the empty payload is the bug this drag had")
        #expect(TabDragPayload.tabID(from: payload) == tabID)

        board.releaseGlobally()
    }

    @Test("A payload that is not one of ours is refused, not guessed at")
    func rejectsForeignPayloads() {
        #expect(TabDragPayload.tabID(from: Data()) == nil)
        #expect(TabDragPayload.tabID(from: Data("not a uuid".utf8)) == nil)
        #expect(TabDragPayload.tabID(from: Data([0xFF, 0xFE, 0xFD])) == nil)
    }

    @Test("The dragged type is ours alone, so no text field can accept a tab")
    func usesADedicatedPasteboardType() {
        #expect(NSPasteboard.PasteboardType.browserTab.rawValue == "com.rizal.browser.tab")
        #expect(NSPasteboard.PasteboardType.browserTab != .string)
    }
}
