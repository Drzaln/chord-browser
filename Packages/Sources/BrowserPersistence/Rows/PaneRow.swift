import Foundation
import GRDB

struct PaneRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "pane"

    var id: String
    var tabId: String
    var position: Int
    var url: String
    var title: String
    var faviconData: Data?
    var widthFraction: Double
}

/// interactionState lives alone so a tab-list load never pulls the blobs (6.5).
struct PaneInteractionStateRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "paneInteractionState"

    var paneId: String
    var data: Data
    var updatedAt: Double
}
