import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A sidebar tab in flight, for dragging one into the content area to split
/// (4.5).
///
/// A dedicated type rather than a plain string: dragging a bare `String` would
/// let any text field in the app accept a tab, and would let arbitrary dragged
/// text look like a tab to us.
struct DraggedTab: Codable, Transferable {
    let tabID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .browserTab)
    }
}

extension UTType {
    /// In-process only — the drag never leaves the app, so this does not need a
    /// declaration in Info.plist.
    static let browserTab = UTType(exportedAs: "com.rizal.browser.tab", conformingTo: .data)
}
