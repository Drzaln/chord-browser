import Foundation

/// Chrome's reading list, backed by a small JSON file.
///
/// It is deliberately separate from `BookmarksStore`: Chrome's `readingList`
/// is a queue with a read flag, not a bookmark tree, and extensions that use it
/// (Pocket-style readers) expect `creationTime`/`lastUpdateTime` and
/// `hasBeenRead` to round-trip.
public struct ReadingListEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var url: String
    public var title: String
    public var created: Date
    public var updated: Date
    public var hasBeenRead: Bool

    public init(
        id: UUID = UUID(), url: String, title: String = "",
        created: Date = Date(), updated: Date = Date(), hasBeenRead: Bool = false
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.created = created
        self.updated = updated
        self.hasBeenRead = hasBeenRead
    }
}

@MainActor
public final class ReadingListStore {
    private let fileURL: URL
    public private(set) var entries: [ReadingListEntry] = []

    public init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    public func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            entries = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([ReadingListEntry].self, from: data)) ?? []
    }

    @discardableResult
    public func add(
        url: String, title: String = "", hasBeenRead: Bool = false
    ) -> ReadingListEntry {
        if let index = entries.firstIndex(where: { $0.url == url }) {
            entries[index].title = title
            entries[index].hasBeenRead = hasBeenRead
            entries[index].updated = Date()
            save()
            return entries[index]
        }
        let entry = ReadingListEntry(url: url, title: title, hasBeenRead: hasBeenRead)
        entries.insert(entry, at: 0)
        save()
        return entry
    }

    @discardableResult
    public func remove(url: String) -> Bool {
        let before = entries.count
        entries.removeAll { $0.url == url }
        guard entries.count != before else { return false }
        save()
        return true
    }

    @discardableResult
    public func update(
        url: String, title: String?, hasBeenRead: Bool?
    ) -> ReadingListEntry? {
        guard let index = entries.firstIndex(where: { $0.url == url }) else {
            return nil
        }
        if let title { entries[index].title = title }
        if let hasBeenRead { entries[index].hasBeenRead = hasBeenRead }
        entries[index].updated = Date()
        save()
        return entries[index]
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
