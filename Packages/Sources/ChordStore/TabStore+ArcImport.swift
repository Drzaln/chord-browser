import ChordCore
import Foundation

/// What one Arc import actually wrote.
///
/// `parserSkipped` and the flags are carried from the plan so the caller can
/// report the whole picture after applying, not only the part that was new to
/// this profile.
public struct ArcImportResult: Sendable, Equatable {
    public let spacesCreated: Int
    public let spacesReused: Int
    public let foldersCreated: Int
    public let foldersReused: Int
    public let pinsAdded: Int
    /// Pins the plan wanted but this Space already had in the same folder.
    public let pinsSkippedExisting: Int
    public let favouritesAdded: Int
    /// Favourites the plan wanted but this Space already had.
    public let favouritesSkippedExisting: Int
    /// Pages and items the parser refused.
    public let parserSkipped: Int
    public let depthLimitReached: Bool
    public let credentialsStripped: Int
    public let itemLimitReached: Bool

    public init(
        spacesCreated: Int,
        spacesReused: Int,
        foldersCreated: Int,
        foldersReused: Int,
        pinsAdded: Int,
        pinsSkippedExisting: Int,
        favouritesAdded: Int,
        favouritesSkippedExisting: Int,
        parserSkipped: Int,
        depthLimitReached: Bool,
        credentialsStripped: Int,
        itemLimitReached: Bool
    ) {
        self.spacesCreated = spacesCreated
        self.spacesReused = spacesReused
        self.foldersCreated = foldersCreated
        self.foldersReused = foldersReused
        self.pinsAdded = pinsAdded
        self.pinsSkippedExisting = pinsSkippedExisting
        self.favouritesAdded = favouritesAdded
        self.favouritesSkippedExisting = favouritesSkippedExisting
        self.parserSkipped = parserSkipped
        self.depthLimitReached = depthLimitReached
        self.credentialsStripped = credentialsStripped
        self.itemLimitReached = itemLimitReached
    }

    public var addedCount: Int { pinsAdded + favouritesAdded }

    public var didWriteAnything: Bool {
        spacesCreated > 0 || foldersCreated > 0 || addedCount > 0
    }
}

/// Applies a parsed Arc sidebar. The plan is the only input: parsing lives in
/// `ChordCore` and never writes, so a corrupt file cannot leave a half-import.
@MainActor
extension TabStore {

    /// Writes an Arc plan into this profile.
    ///
    /// Mapping (see `ArcSidebarParser` for the schema handling):
    ///   - Arc Space → Chord `Space`, matched by name (case-insensitive) so a
    ///     re-import reuses it instead of creating a twin.
    ///   - Arc Pinned list → `.bookmarked` tabs, homed at the Arc URL.
    ///   - Arc top apps → `.pinned` favourites, homed at the Arc URL.
    ///   - Arc folders → flat `Folder`s named `Parent / Child`, because Chord's
    ///     folder model has no parent pointer.
    ///
    /// Re-importing the same plan is a no-op: Spaces and folders match by name,
    /// pins by (folder, URL), favourites by URL. Private windows are refused —
    /// their Space is not persisted, so anything imported there would vanish on
    /// close. Archives are not touched; this only appends sidebar entries.
    @discardableResult
    public func importArc(
        _ plan: ArcImportPlan, in window: WindowState
    ) -> ArcImportResult {
        let refused = ArcImportResult(
            spacesCreated: 0,
            spacesReused: 0,
            foldersCreated: 0,
            foldersReused: 0,
            pinsAdded: 0,
            pinsSkippedExisting: 0,
            favouritesAdded: 0,
            favouritesSkippedExisting: 0,
            parserSkipped: plan.skippedCount,
            depthLimitReached: plan.depthLimitReached,
            credentialsStripped: plan.credentialsStripped,
            itemLimitReached: plan.itemLimitReached
        )
        guard !window.isPrivate else { return refused }

        var spacesCreated = 0
        var spacesReused = 0
        var foldersCreated = 0
        var foldersReused = 0
        var pinsAdded = 0
        var pinsSkipped = 0
        var favouritesAdded = 0
        var favouritesSkipped = 0
        var touchedSpaces: Set<UUID> = []

        for arcSpace in plan.spaces {
            let name = arcSpace.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let spaceName = name.isEmpty ? String(localized: "Arc Import") : name
            let spaceID: UUID
            if let existing = spaces.first(where: {
                !$0.isPrivate
                    && $0.name.caseInsensitiveCompare(spaceName) == .orderedSame
            }) {
                spaceID = existing.id
                spacesReused += 1
            } else {
                let sortIndex = (spaces.map(\.sortIndex).max() ?? -1) + 1
                let space = Space(
                    name: spaceName,
                    iconSymbol: arcSpace.icon ?? "circle.grid.2x2",
                    gradient: Space.gradient(forIndex: sortIndex),
                    sortIndex: sortIndex
                )
                spaces.append(space)
                spaceID = space.id
                spacesCreated += 1
            }

            var folderIDs: [[String]: UUID] = [:]
            var nextFolderSortIndex = (folders
                .filter { $0.spaceID == spaceID }
                .map(\.sortIndex)
                .max() ?? -1) + 1

            // Plan folders first, so an empty Arc folder still appears. Every
            // tab path is also created on demand below, so a hand-built plan
            // missing its `folders` list cannot lose a tab.
            for imported in arcSpace.folders {
                _ = arcFolderID(
                    for: imported.path,
                    in: spaceID,
                    known: &folderIDs,
                    nextSortIndex: &nextFolderSortIndex,
                    created: &foldersCreated,
                    reused: &foldersReused
                )
            }

            let pins = importPins(
                arcSpace.pinned,
                into: spaceID,
                folderIDs: &folderIDs,
                nextFolderSortIndex: &nextFolderSortIndex,
                foldersCreated: &foldersCreated,
                foldersReused: &foldersReused
            )
            pinsAdded += pins.added
            pinsSkipped += pins.skipped

            let favourites = importFavourites(arcSpace.favourites, into: spaceID)
            favouritesAdded += favourites.added
            favouritesSkipped += favourites.skipped

            if pins.added + favourites.added > 0 {
                touchedSpaces.insert(spaceID)
            }
        }

        if spacesCreated > 0 {
            Task { await persistSpaces() }
        }
        if foldersCreated > 0 {
            persistFolders()
        }
        if !touchedSpaces.isEmpty {
            // A Space that was left blank should show the entries that just
            // arrived rather than keep offering the command bar over them.
            for spaceID in touchedSpaces { window.blankSpaceIDs.remove(spaceID) }
            scheduleSave()
        }

        return ArcImportResult(
            spacesCreated: spacesCreated,
            spacesReused: spacesReused,
            foldersCreated: foldersCreated,
            foldersReused: foldersReused,
            pinsAdded: pinsAdded,
            pinsSkippedExisting: pinsSkipped,
            favouritesAdded: favouritesAdded,
            favouritesSkippedExisting: favouritesSkipped,
            parserSkipped: plan.skippedCount,
            depthLimitReached: plan.depthLimitReached,
            credentialsStripped: plan.credentialsStripped,
            itemLimitReached: plan.itemLimitReached
        )
    }

    // MARK: - Folders

    /// The Chord folder for a flat path, creating it once per Space and
    /// reusing an existing folder of the same display name.
    private func arcFolderID(
        for path: [String],
        in spaceID: UUID,
        known: inout [[String]: UUID],
        nextSortIndex: inout Int,
        created: inout Int,
        reused: inout Int
    ) -> UUID? {
        guard !path.isEmpty else { return nil }
        if let id = known[path] { return id }
        let name = path.joined(separator: " / ")
        if let existing = folders.first(where: {
            $0.spaceID == spaceID && $0.name == name
        }) {
            known[path] = existing.id
            reused += 1
            return existing.id
        }
        let folder = Folder(
            spaceID: spaceID, name: name, sortIndex: nextSortIndex
        )
        nextSortIndex += 1
        folders.append(folder)
        known[path] = folder.id
        created += 1
        return folder.id
    }

    // MARK: - Tabs

    private struct Tally {
        var added = 0
        var skipped = 0
    }

    /// Inserts Arc Pinned tabs as `.bookmarked` entries, de-duplicated by
    /// (folder, URL) within the Space.
    private func importPins(
        _ pins: [ArcImportTab],
        into spaceID: UUID,
        folderIDs: inout [[String]: UUID],
        nextFolderSortIndex: inout Int,
        foldersCreated: inout Int,
        foldersReused: inout Int
    ) -> Tally {
        struct Key: Hashable {
            let folderID: UUID?
            let url: String
        }

        var existing: Set<Key> = []
        for tab in tabs where tab.spaceID == spaceID && tab.placement.isBookmarked {
            let url = (tab.placement.homeURL ?? tab.focusedPane.url).absoluteString
            existing.insert(Key(folderID: tab.folderID, url: url))
        }
        var nextOrder = (tabs
            .filter { $0.spaceID == spaceID && $0.placement.isBookmarked }
            .map(\.placement.order)
            .max() ?? -1) + 1

        var tally = Tally()
        for pin in pins {
            let folderID = arcFolderID(
                for: pin.folderPath,
                in: spaceID,
                known: &folderIDs,
                nextSortIndex: &nextFolderSortIndex,
                created: &foldersCreated,
                reused: &foldersReused
            )
            let key = Key(folderID: folderID, url: pin.url.absoluteString)
            guard existing.insert(key).inserted else {
                tally.skipped += 1
                continue
            }

            let pane = Pane(url: pin.url, title: pin.title)
            tabs.append(
                Tab(
                    spaceID: spaceID,
                    placement: .bookmarked(order: nextOrder, homeURL: pin.url),
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
            tally.added += 1
        }
        return tally
    }

    /// Inserts Arc top apps as favourites. Favourites are always top-level in
    /// Chord — a foldered tab renders under the folder, not in the icon grid —
    /// so any folder Arc put a top app in is flattened away here.
    private func importFavourites(
        _ favourites: [ArcImportTab], into spaceID: UUID
    ) -> Tally {
        var existing: Set<String> = []
        for tab in tabs where tab.spaceID == spaceID && tab.placement.isPinned {
            let url = (tab.placement.homeURL ?? tab.focusedPane.url).absoluteString
            existing.insert(url)
        }
        var nextOrder = (tabs
            .filter { $0.spaceID == spaceID && $0.placement.isPinned }
            .map(\.placement.order)
            .max() ?? -1) + 1

        var tally = Tally()
        for favourite in favourites {
            guard existing.insert(favourite.url.absoluteString).inserted else {
                tally.skipped += 1
                continue
            }
            let pane = Pane(url: favourite.url, title: favourite.title)
            tabs.append(
                Tab(
                    spaceID: spaceID,
                    placement: .pinned(order: nextOrder, homeURL: favourite.url),
                    panes: [pane],
                    focusedPaneID: pane.id,
                    lastAccessedAt: clock.now,
                    createdAt: clock.now
                )
            )
            stateResolution[pane.id] = .resolved
            nextOrder += 1
            tally.added += 1
        }
        return tally
    }
}
