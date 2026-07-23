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

    /// The payload as AppKit wants it, for `onDrag`.
    ///
    /// `.ownProcess` visibility: a tab means nothing outside this app, and it
    /// keeps the identifier off the system pasteboard.
    var itemProvider: NSItemProvider {
        let provider = NSItemProvider()
        let id = tabID
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.browserTab.identifier, visibility: .ownProcess
        ) { completion in
            completion(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    /// Reads back what `itemProvider` wrote, delivering the result on the main
    /// actor. The provider itself never crosses an isolation boundary.
    static func loadTabID(
        from provider: NSItemProvider, completion: @escaping @MainActor (UUID?) -> Void
    ) {
        _ = provider.loadDataRepresentation(
            forTypeIdentifier: UTType.browserTab.identifier
        ) { data, _ in
            let tabID = data
                .flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(UUID.init(uuidString:))
            Task { @MainActor in completion(tabID) }
        }
    }
}

extension UTType {
    /// In-process only — the drag never leaves the app, so this does not need a
    /// declaration in Info.plist.
    static let browserTab = UTType(exportedAs: "com.rizal.browser.tab", conformingTo: .data)
}
