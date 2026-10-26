import Foundation

/// A bookmark as Chrome's extension API describes one.
///
/// Chord does not have a bookmarks UI yet; this model exists so extensions that
/// rely on `chrome.bookmarks` have somewhere real to read and write instead of
/// an empty lie. A folder has no URL; both roots are represented by fixed ids
/// in `BookmarksStore`.
public struct Bookmark: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var parentID: UUID?
    public var title: String
    public var url: URL?
    public var dateAdded: Date
    public var index: Int

    public init(
        id: UUID = UUID(),
        parentID: UUID? = nil,
        title: String,
        url: URL? = nil,
        dateAdded: Date = Date(),
        index: Int = 0
    ) {
        self.id = id
        self.parentID = parentID
        self.title = title
        self.url = url
        self.dateAdded = dateAdded
        self.index = index
    }

    public var isFolder: Bool { url == nil }
}
