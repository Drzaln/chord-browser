import Foundation

/// A named, collapsible group of tabs within a Space (non-spec: user-requested).
///
/// A tab belongs to at most one folder (`Tab.folderID`). Folder membership is
/// independent of pinning; a foldered tab is exempt from the ephemeral sweep, so
/// a folder is a place to keep tabs you care about, organised.
public struct Folder: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var spaceID: UUID
    public var name: String
    public var sortIndex: Int
    public var isCollapsed: Bool

    public init(
        id: UUID = UUID(),
        spaceID: UUID,
        name: String,
        sortIndex: Int,
        isCollapsed: Bool = false
    ) {
        self.id = id
        self.spaceID = spaceID
        self.name = name
        self.sortIndex = sortIndex
        self.isCollapsed = isCollapsed
    }

    public var displayName: String {
        name.isEmpty ? "Untitled Folder" : name
    }
}
