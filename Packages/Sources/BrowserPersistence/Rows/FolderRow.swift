import Foundation
import GRDB

/// The on-disk shape of a sidebar folder (non-spec: user-requested).
struct FolderRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "folder"

    var id: String
    var spaceId: String
    var name: String
    var sortIndex: Int
    var isCollapsed: Bool
}
