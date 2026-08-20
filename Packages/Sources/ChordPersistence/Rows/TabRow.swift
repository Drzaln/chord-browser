import Foundation
import GRDB

/// The on-disk shape of a tab. Deliberately separate from `ChordCore.Tab`:
/// renaming a field in the app model must never break an existing profile (7.2).
struct TabRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "tab"

    var id: String
    var spaceId: String
    var placementKind: String
    var placementOrder: Int
    /// The URL an Arc *Pinned* tab returns to, or nil for the other tiers
    /// (non-spec: user-requested). Only set when `placementKind == "bookmarked"`.
    var pinnedHomeURL: String?
    /// The folder this tab belongs to, or nil (non-spec: user-requested).
    var folderId: String?
    var focusedPaneID: String
    var lastAccessedAt: Double
    var createdAt: Double

    static let panes = hasMany(PaneRow.self)
}
