import Foundation

/// One visited page. Title and URL only — full-text search over page content
/// was considered and declined for M3 (BROWSER_SPEC 12, ADR 007).
public struct HistoryEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var url: URL
    public var title: String
    public var lastVisitedAt: Date
    public var visitCount: Int

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        lastVisitedAt: Date,
        visitCount: Int = 1
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.lastVisitedAt = lastVisitedAt
        self.visitCount = visitCount
    }

    public var displayTitle: String {
        title.isEmpty ? (url.host() ?? url.absoluteString) : title
    }
}

/// A tab the sweep closed. Recoverable from the command bar; never hard-deleted
/// by the sweep itself (4.3).
public struct ArchivedTab: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var url: URL
    public var title: String
    public var faviconData: Data?
    public var spaceID: UUID
    public var archivedAt: Date

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        faviconData: Data? = nil,
        spaceID: UUID,
        archivedAt: Date
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.faviconData = faviconData
        self.spaceID = spaceID
        self.archivedAt = archivedAt
    }

    /// Built from the tab being swept. `interactionState` is deliberately not
    /// carried across: the blobs are large, and an archived tab needs to be
    /// findable, not scroll-accurate (6.5).
    public init(tab: Tab, archivedAt: Date) {
        let pane = tab.focusedPane
        self.init(
            url: pane.url,
            title: pane.displayTitle,
            faviconData: pane.faviconData,
            spaceID: tab.spaceID,
            archivedAt: archivedAt
        )
    }

    public var displayTitle: String {
        title.isEmpty ? (url.host() ?? url.absoluteString) : title
    }
}

public protocol HistoryRepository: Sendable {
    /// Upserts by URL, bumping `visitCount` and `lastVisitedAt`.
    func recordVisit(url: URL, title: String, at date: Date) async throws
    func recentHistory(limit: Int) async throws -> [HistoryEntry]
}

public protocol ArchiveRepository: Sendable {
    func archive(_ tabs: [ArchivedTab]) async throws
    func archivedTabs() async throws -> [ArchivedTab]
}
