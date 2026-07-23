import Foundation
import GRDB

/// The on-disk shape of a tab. Deliberately separate from `BrowserCore.Tab`:
/// renaming a field in the app model must never break an existing profile (7.2).
struct TabRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "tab"

    var id: String
    var spaceId: String
    var placementKind: String
    var placementOrder: Int
    var focusedPaneID: String
    var lastAccessedAt: Double
    var createdAt: Double

    static let panes = hasMany(PaneRow.self)
}
