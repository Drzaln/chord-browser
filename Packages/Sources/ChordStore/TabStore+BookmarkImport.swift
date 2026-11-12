import ChordCore
import Foundation

/// What one bookmark import actually wrote. `parserSkipped` is carried from the
/// plan so the caller can report the whole picture after applying, not only the
/// part that was new to this profile.
public struct BookmarkImportResult: Sendable, Equatable {
    public let foldersCreated: Int
    public let foldersReused: Int
    public let entriesAdded: Int
    /// Entries the plan wanted but this profile already had in the same folder.
    public let entriesSkippedExisting: Int
    /// Entries and malformed lines the parser refused.
    public let parserSkipped: Int
    public let depthLimitReached: Bool

    public init(
        foldersCreated: Int,
        foldersReused: Int,
        entriesAdded: Int,
        entriesSkippedExisting: Int,
        parserSkipped: Int,
        depthLimitReached: Bool
    ) {
        self.foldersCreated = foldersCreated
        self.foldersReused = foldersReused
        self.entriesAdded = entriesAdded
        self.entriesSkippedExisting = entriesSkippedExisting
        self.parserSkipped = parserSkipped
        self.depthLimitReached = depthLimitReached
    }

    public var didWriteAnything: Bool { foldersCreated > 0 || entriesAdded > 0 }
}

@MainActor
extension TabStore {

    /// Writes a parsed plan into `window`'s active Space.
    ///
    /// Chord has no separate bookmark database: a bookmark is an Arc-style
    /// *Pinned* tab, and a folder is the existing sidebar `Folder` tree. This
    /// goes through the store's in-memory state and its existing repositories
    /// (`TabRepository` / `FolderRepository`) — the same path every other tab
    /// and folder mutation uses, with one debounced save.
    ///
    /// Root-level entries become top-level Pinned tabs; nested export paths
    /// become flat folders named `Parent / Child`, because Chord's folder model
    /// is flat. Re-importing the same file is a no-op: folders are matched by
    /// name and bookmarks by URL within their target folder.
    @discardableResult
    public func importBookmarks(
        _ plan: BookmarkImportPlan, in window: WindowState
    ) -> BookmarkImportResult {
        guard let spaceID = activeSpace(in: window)?.id, !isPrivate(spaceID: spaceID) else {
            return BookmarkImportResult(
                foldersCreated: 0,
                foldersReused: 0,
                entriesAdded: 0,
                entriesSkippedExisting: 0,
                parserSkipped: plan.skippedCount,
                depthLimitReached: plan.depthLimitReached
            )
        }

        let foldersCreated = createFolders(from: plan, inSpace: spaceID)

        // Existing bookmarks keyed by their target folder, so a second import
        // of the same file lands nothing twice. Favourites are a different
        // tier, so only Pinned tabs count in the root folder.
        struct BookmarkKey: Hashable {
            let folderID: UUID?
            let url: String
        }
        var existing: Set<BookmarkKey> = []
        for tab in tabs where tab.spaceID == spaceID {
            let url = (tab.placement.homeURL ?? tab.focusedPane.url).absoluteString
            if let folderID = tab.folderID {
                existing.insert(BookmarkKey(folderID: folderID, url: url))
            } else if tab.placement.isBookmarked {
                existing.insert(BookmarkKey(folderID: nil, url: url))
            }
        }

        var nextOrder = (tabs
            .filter { $0.spaceID == spaceID && $0.placement.isBookmarked }
            .map(\.placement.order)
            .max() ?? -1) + 1
        var added = 0
        var skippedExisting = 0

        for entry in plan.entries {
            let folderID = entry.folderPath.isEmpty
                ? nil
                : foldersCreated.ids[entry.folderPath]
            let key = BookmarkKey(folderID: folderID, url: entry.url.absoluteString)
            guard existing.insert(key).inserted else {
                skippedExisting += 1
                continue
            }

            let pane = Pane(url: entry.url, title: entry.title)
            tabs.append(
                Tab(
                    spaceID: spaceID,
                    placement: .bookmarked(order: nextOrder, homeURL: entry.url),
                    folderID: folderID,
                    panes: [pane],
                    focusedPaneID: pane.id,
                    lastAccessedAt: clock.now,
                    createdAt: clock.now
                )
            )
            // A brand-new pane has nothing stored, exactly like `insertTab`.
            stateResolution[pane.id] = .resolved
            nextOrder += 1
            added += 1
        }

        if added > 0 {
            window.blankSpaceIDs.remove(spaceID)
            scheduleSave()
        }

        return BookmarkImportResult(
            foldersCreated: foldersCreated.count,
            foldersReused: foldersCreated.reused,
            entriesAdded: added,
            entriesSkippedExisting: skippedExisting,
            parserSkipped: plan.skippedCount,
            depthLimitReached: plan.depthLimitReached
        )
    }

    /// Creates the plan's folders in `spaceID`, reusing one of the same name
    /// that is already there. Returns the path→id map and write counters.
    private func createFolders(
        from plan: BookmarkImportPlan, inSpace spaceID: UUID
    ) -> (ids: [[String]: UUID], count: Int, reused: Int) {
        var ids: [[String]: UUID] = [:]
        var created = 0
        var reused = 0
        var nextSortIndex = (folders
            .filter { $0.spaceID == spaceID }
            .map(\.sortIndex)
            .max() ?? -1) + 1

        for imported in plan.folders {
            let name = imported.displayName
            if let existing = folders.first(where: {
                $0.spaceID == spaceID && $0.name == name
            }) {
                ids[imported.path] = existing.id
                reused += 1
                continue
            }

            let folder = Folder(
                spaceID: spaceID, name: name, sortIndex: nextSortIndex
            )
            nextSortIndex += 1
            folders.append(folder)
            ids[imported.path] = folder.id
            created += 1
        }

        if created > 0 { persistFolders() }
        return (ids, created, reused)
    }
}
