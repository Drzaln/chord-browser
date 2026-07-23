import AppKit
import UniformTypeIdentifiers

/// What a sidebar tab in flight puts on the dragging pasteboard, for dragging
/// one into the content area to split it (4.5).
///
/// Both ends of the drag go through here — `TabDragSource` writes, and
/// `TabDropTarget` reads. They are two files that have to agree on a byte
/// format, which is exactly the kind of pair that drifts silently: the
/// destination cannot tell "the source wrote something else" from "the source
/// wrote nothing", and both look like a drop that did nothing.
enum TabDragPayload {
    static func data(for tabID: UUID) -> Data {
        Data(tabID.uuidString.utf8)
    }

    static func tabID(from data: Data) -> UUID? {
        String(data: data, encoding: .utf8).flatMap(UUID.init(uuidString:))
    }
}

extension UTType {
    /// The pasteboard type for a dragged tab.
    ///
    /// A dedicated type rather than a plain string: dragging a bare `String`
    /// would let any text field in the app accept a tab, and would let
    /// arbitrary dragged text look like a tab to us.
    ///
    /// In-process only — the drag never leaves the app (`TabDragSource` offers
    /// no operation outside it), so this needs no declaration in Info.plist.
    static let browserTab = UTType(exportedAs: "com.rizal.browser.tab", conformingTo: .data)
}

extension NSPasteboard.PasteboardType {
    static let browserTab = NSPasteboard.PasteboardType(UTType.browserTab.identifier)
}
