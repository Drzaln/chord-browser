import ChordCore
import Foundation
import Observation

/// A small JSON-backed bookmarks store for `chrome.bookmarks`.
///
/// The browser has no bookmarks UI yet, so this is deliberately data-only: it
/// keeps the extension API honest and can grow a sidebar/menu later without
/// changing the stored shape. `barID` and `otherID` are stable synthetic ids
/// for Chrome's two roots.
@MainActor
@Observable
public final class BookmarksStore {
    public static let barID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    public static let otherID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    public static let rootID = UUID(uuidString: "00000000-0000-4000-8000-000000000000")!

    public private(set) var items: [Bookmark] = []
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var loaded = false

    public init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    public func load() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Bookmark].self, from: data)
        else { return }
        items = decoded
    }

    public func children(of parentID: UUID?) -> [Bookmark] {
        items
            .filter { $0.parentID == parentID }
            .sorted { $0.index < $1.index }
    }

    public func all(in parentID: UUID?, deep: Bool) -> [Bookmark] {
        let direct = children(of: parentID)
        guard deep else { return direct }
        return direct + direct.flatMap { all(in: $0.id, deep: true) }
    }

    public func find(_ id: UUID) -> Bookmark? { items.first { $0.id == id } }

    @discardableResult
    public func insert(
        title: String, url: URL?, parentID: UUID?, at index: Int? = nil
    ) -> Bookmark {
        load()
        let parent = parentID ?? Self.barID
        let siblings = children(of: parent)
        let position = min(max(index ?? siblings.count, 0), siblings.count)
        for sibling in siblings where sibling.index >= position {
            if let at = items.firstIndex(where: { $0.id == sibling.id }) {
                items[at].index += 1
            }
        }
        let item = Bookmark(
            parentID: parent, title: title, url: url, index: position
        )
        items.append(item)
        save()
        return item
    }

    public func update(_ id: UUID, title: String?, url: URL?) {
        load()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let title { items[index].title = title }
        if let url { items[index].url = url }
        save()
    }

    public func move(_ id: UUID, to parentID: UUID?, at index: Int?) {
        load()
        guard let at = items.firstIndex(where: { $0.id == id }) else { return }
        let oldParent = items[at].parentID
        let parent = parentID ?? oldParent
        // Remove from the old sibling order.
        for sibling in children(of: oldParent) where sibling.index > items[at].index {
            if let siblingIndex = items.firstIndex(where: { $0.id == sibling.id }) {
                items[siblingIndex].index -= 1
            }
        }
        items[at].parentID = parent
        let siblings = children(of: parent).filter { $0.id != id }
        let position = min(max(index ?? siblings.count, 0), siblings.count)
        for sibling in siblings where sibling.index >= position {
            if let siblingIndex = items.firstIndex(where: { $0.id == sibling.id }) {
                items[siblingIndex].index += 1
            }
        }
        items[at].index = position
        save()
    }

    public func remove(_ id: UUID) {
        load()
        let doomed = all(in: id, deep: true).map(\.id) + [id]
        items.removeAll { doomed.contains($0.id) }
        save()
    }

    public func search(_ words: String) -> [Bookmark] {
        load()
        let query = words.lowercased().split(separator: " ")
        guard !query.isEmpty else { return [] }
        return items.filter { item in
            let haystack = (item.title + " " + (item.url?.absoluteString ?? "")).lowercased()
            return query.allSatisfy { haystack.contains($0) }
        }
    }

    private func save() {
        guard let fileURL,
              let data = try? JSONEncoder().encode(items)
        else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
