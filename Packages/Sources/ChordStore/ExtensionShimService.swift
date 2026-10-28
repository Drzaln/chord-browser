import ChordCore
import ChordExtensions
import Foundation

/// Store-side answers for the Chrome APIs that need Chord's own data:
/// bookmarks, history, downloads, side panel fallback, folders-as-tabGroups,
/// sessions, top sites and search.
///
/// The WebKit-specific half (offscreen documents, permission sheets, action
/// popovers, tab descriptors) stays in `ChordExtensions`; this object never
/// imports WebKit and is injected into `WebKitExtensionHost.shimData`.
@MainActor
public final class ExtensionShimService: ExtensionShimData {
    private unowned let store: TabStore
    private let downloads: DownloadsStore
    private let bookmarks: BookmarksStore
    private let readingList: ReadingListStore

    /// Side-panel options are per extension and persist across launches, as
    /// Chrome's do. `open` reaches the docked panel; the tab fallback remains
    /// for hosts without one.
    private let defaults: UserDefaults
    /// The docked side panel, when the app can show one. Nil leaves the
    /// fallback of opening the panel's page as a normal tab.
    public var onSidePanel: (@MainActor (ExtensionShimContext, URL) -> Void)?

    public init(
        store: TabStore, downloads: DownloadsStore, bookmarks: BookmarksStore,
        readingList: ReadingListStore, defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.downloads = downloads
        self.bookmarks = bookmarks
        self.readingList = readingList
        self.defaults = defaults
        bookmarks.load()
    }

    public func answer(
        _ api: String, args: [Any], context: ExtensionShimContext
    ) async throws -> Any? {
        switch api {
        case "bookmarks.getTree", "bookmarks.getSubTree", "bookmarks.getChildren",
             "bookmarks.get", "bookmarks.getRecent", "bookmarks.search",
             "bookmarks.create", "bookmarks.update", "bookmarks.move",
             "bookmarks.remove", "bookmarks.removeTree":
            return try answerBookmarks(api, args)
        case "history.search", "history.getVisits", "history.addUrl",
             "history.deleteUrl", "history.deleteRange", "history.deleteAll":
            return try await answerHistory(api, args, context: context)
        case "downloads.search":
            return downloads.downloads.enumerated().map {
                downloadJSON($0.element, id: $0.offset + 1)
            }
        case "downloads.download":
            let spec = args.first as? [String: Any] ?? [:]
            guard let raw = spec["url"] as? String, let url = URL(string: raw),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else { throw Unsupported(what: "That isn't a downloadable address") }
            downloads.start(
                url: url, suggestedFilename: spec["filename"] as? String
            )
            // Chrome's download ids are integers; the newest is first in this
            // list, so it is id 1 to `downloads.search` until the next one.
            return 1
        case "downloads.open":
            guard let id = args.first as? Int, downloads.downloads.indices.contains(id - 1)
            else { throw Unsupported(what: "No such download") }
            downloads.open(downloads.downloads[id - 1].id)
            return nil
        case "downloads.show":
            guard let id = args.first as? Int, downloads.downloads.indices.contains(id - 1)
            else { throw Unsupported(what: "No such download") }
            downloads.show(downloads.downloads[id - 1].id)
            return nil
        case "downloads.showDefaultFolder", "downloads.erase":
            return nil
        case "sidePanel.setOptions", "sidePanel.getOptions",
             "sidePanel.setPanelBehavior", "sidePanel.getPanelBehavior",
             "sidePanel.open", "sidePanel.close":
            return try answerSidePanel(api, args, context: context)
        case "tabGroups.query", "tabGroups.get", "tabGroups.update", "tabGroups.move":
            return try answerTabGroups(api, args, context: context)
        case "tabs.group", "tabs.ungroup":
            return try answerTabGrouping(api, args, context: context)
        case "sessions.getRecentlyClosed":
            return await recentlyClosed(context: context)
        case "sessions.getDevices":
            return []
        case "sessions.restore":
            return nil
        case "topSites.get":
            return await topSites(context: context)
        case "readingList.query":
            return try answerReadingList(api, args)
        case "readingList.addEntry", "readingList.removeEntry",
             "readingList.updateEntry":
            return try answerReadingList(api, args)
        case "search.query":
            return answerSearch(args, context: context)
        case "browsingData.settings":
            return ["options": [:], "dataToRemove": [:], "dataRemovalPermitted": [:]]
        case "browsingData.remove", "browsingData.removePasswords",
             "browsingData.removeCache", "browsingData.removeCookies",
             "browsingData.removeDownloads", "browsingData.removeFormData",
             "browsingData.removeHistory", "browsingData.removeLocalStorage":
            return nil
        default:
            throw Unsupported(what: "\(api) isn't available in Chord yet")
        }
    }

    // MARK: - Bookmarks

    private func answerBookmarks(_ api: String, _ args: [Any]) throws -> Any? {
        switch api {
        case "bookmarks.getTree":
            return [rootNode(deep: true)]
        case "bookmarks.getSubTree":
            guard let id = args.first as? String else { return [] }
            if id == "0" { return [rootNode(deep: true)] }
            if id == "1" { return [barNode(deep: true)] }
            if id == "2" { return [otherNode(deep: true)] }
            guard let uuid = UUID(uuidString: id), let item = bookmarks.find(uuid)
            else { return [] }
            return [node(item, parent: item.parentID, deep: true)]
        case "bookmarks.getChildren":
            let id = args.first as? String ?? "1"
            if id == "0" { return [barNode(deep: false), otherNode(deep: false)] }
            let parent = id == "1" ? BookmarksStore.barID
                : id == "2" ? BookmarksStore.otherID : UUID(uuidString: id)
            return bookmarks.children(of: parent).enumerated().map {
                node($0.element, parent: parent, index: $0.offset, deep: false)
            }
        case "bookmarks.get":
            let ids: [String] = (args.first as? [String])
                ?? (args.first as? String).map { [$0] } ?? []
            return ids.compactMap { id -> [String: Any]? in
                guard let uuid = UUID(uuidString: id), let item = bookmarks.find(uuid)
                else { return nil }
                return node(item, parent: item.parentID, deep: false)
            }
        case "bookmarks.getRecent":
            let count = args.first as? Int ?? 10
            return bookmarks.items
                .filter { !$0.isFolder }
                .sorted { $0.dateAdded > $1.dateAdded }
                .prefix(count)
                .map { node($0, parent: $0.parentID, deep: false) }
        case "bookmarks.search":
            let text = (args.first as? String)
                ?? (args.first as? [String: Any])?["query"] as? String ?? ""
            return bookmarks.search(text).map { node($0, parent: $0.parentID, deep: false) }
        case "bookmarks.create":
            let spec = args.first as? [String: Any] ?? [:]
            let title = spec["title"] as? String ?? ""
            let parent = parentUUID(spec["parentId"] as? String)
            let url = (spec["url"] as? String).flatMap(URL.init(string:))
            let made = bookmarks.insert(
                title: title, url: url, parentID: parent, at: spec["index"] as? Int
            )
            return node(made, parent: parent, deep: false)
        case "bookmarks.update":
            guard let id = args.first as? String, let uuid = UUID(uuidString: id),
                  bookmarks.find(uuid) != nil
            else { throw Unsupported(what: "No such bookmark") }
            let changes = args.count > 1 ? args[1] as? [String: Any] ?? [:] : [:]
            bookmarks.update(
                uuid, title: changes["title"] as? String,
                url: (changes["url"] as? String).flatMap(URL.init(string:))
            )
            return bookmarks.find(uuid).map { node($0, parent: $0.parentID, deep: false) }
        case "bookmarks.move":
            guard let id = args.first as? String, let uuid = UUID(uuidString: id),
                  let item = bookmarks.find(uuid)
            else { throw Unsupported(what: "No such bookmark") }
            let spec = (args.count > 1 ? args[1] as? [String: Any] : nil) ?? [:]
            bookmarks.move(
                uuid, to: parentUUID(spec["parentId"] as? String) ?? item.parentID,
                at: spec["index"] as? Int
            )
            return bookmarks.find(uuid).map { node($0, parent: $0.parentID, deep: false) }
        case "bookmarks.remove", "bookmarks.removeTree":
            guard let id = args.first as? String, let uuid = UUID(uuidString: id)
            else { throw Unsupported(what: "No such bookmark") }
            bookmarks.remove(uuid)
            return nil
        default:
            return nil
        }
    }

    private func parentUUID(_ text: String?) -> UUID? {
        switch text {
        case "1": BookmarksStore.barID
        case "2": BookmarksStore.otherID
        case "0": BookmarksStore.barID
        default: text.flatMap(UUID.init(uuidString:))
        }
    }

    private func rootNode(deep: Bool) -> [String: Any] {
        ["id": "0", "title": "", "children": [barNode(deep: deep), otherNode(deep: deep)]]
    }

    private func barNode(deep: Bool) -> [String: Any] {
        folderNode(id: "1", title: "Bookmarks bar", parentID: BookmarksStore.barID, deep: deep)
    }

    private func otherNode(deep: Bool) -> [String: Any] {
        folderNode(id: "2", title: "Other bookmarks", parentID: BookmarksStore.otherID, deep: deep)
    }

    private func folderNode(
        id: String, title: String, parentID: UUID, deep: Bool
    ) -> [String: Any] {
        var value: [String: Any] = ["id": id, "title": title, "parentId": "0"]
        if deep {
            value["children"] = bookmarks.children(of: parentID).enumerated().map {
                node($0.element, parent: parentID, index: $0.offset, deep: true)
            }
        }
        return value
    }

    private func node(
        _ item: Bookmark, parent: UUID?, index: Int? = nil, deep: Bool
    ) -> [String: Any] {
        var value: [String: Any] = [
            "id": item.id.uuidString,
            "title": item.title,
            "dateAdded": item.dateAdded.timeIntervalSince1970 * 1000,
            "index": index ?? item.index,
        ]
        if let url = item.url { value["url"] = url.absoluteString }
        if let parent {
            value["parentId"] = parent == BookmarksStore.barID ? "1"
                : parent == BookmarksStore.otherID ? "2" : parent.uuidString
        }
        if deep {
            value["children"] = bookmarks.children(of: item.id).enumerated().map {
                node($0.element, parent: item.id, index: $0.offset, deep: true)
            }
        }
        return value
    }

    // MARK: - History

    private func answerHistory(
        _ api: String, _ args: [Any], context: ExtensionShimContext
    ) async throws -> Any? {
        let repository = store.historyRepository
        switch api {
        case "history.search":
            let spec = args.first as? [String: Any] ?? [:]
            let text = spec["text"] as? String ?? ""
            let start = (spec["startTime"] as? Double).map {
                Date(timeIntervalSince1970: $0 / 1000)
            } ?? .distantPast
            let end = (spec["endTime"] as? Double).map {
                Date(timeIntervalSince1970: $0 / 1000)
            } ?? .distantFuture
            let limit = spec["maxResults"] as? Int ?? 100
            let entries = try await repository?.recentHistory(
                inSpace: context.spaceID, limit: 5_000
            ) ?? []
            return entries.filter { entry in
                entry.lastVisitedAt >= start && entry.lastVisitedAt <= end
                    && (text.isEmpty || entry.url.absoluteString.localizedCaseInsensitiveContains(text)
                        || entry.title.localizedCaseInsensitiveContains(text))
            }.prefix(limit).map(historyJSON)
        case "history.getVisits":
            let url = (args.first as? [String: Any])?["url"] as? String ?? ""
            return (try await repository?.recentHistory(
                inSpace: context.spaceID, limit: 5_000
            ) ?? []).filter { $0.url.absoluteString == url }.map {
                ["id": $0.id.uuidString, "visitId": "1",
                 "visitTime": $0.lastVisitedAt.timeIntervalSince1970 * 1000,
                 "referringVisitId": "0", "transition": "link"]
            }
        case "history.addUrl":
            if let url = ((args.first as? [String: Any])?["url"] as? String)
                .flatMap(URL.init(string:)) {
                try await repository?.recordVisit(
                    url: url, title: "", spaceID: context.spaceID, at: Date()
                )
            }
            return nil
        case "history.deleteUrl":
            let url = (args.first as? [String: Any])?["url"] as? String ?? ""
            let entries = try await repository?.recentHistory(
                inSpace: context.spaceID, limit: 5_000
            ) ?? []
            try await repository?.deleteHistory(
                ids: entries.filter { $0.url.absoluteString == url }.map(\.id)
            )
            return nil
        case "history.deleteRange":
            let spec = args.first as? [String: Any] ?? [:]
            let start = Date(timeIntervalSince1970: (spec["startTime"] as? Double ?? 0) / 1000)
            let end = Date(timeIntervalSince1970: (spec["endTime"] as? Double ?? 0) / 1000)
            let entries = try await repository?.recentHistory(
                inSpace: context.spaceID, limit: 5_000
            ) ?? []
            try await repository?.deleteHistory(
                ids: entries.filter { $0.lastVisitedAt >= start && $0.lastVisitedAt <= end }.map(\.id)
            )
            return nil
        case "history.deleteAll":
            try await repository?.deleteAllHistory(inSpace: context.spaceID)
            return nil
        default:
            return nil
        }
    }

    private func historyJSON(_ entry: HistoryEntry) -> [String: Any] {
        ["id": entry.id.uuidString, "url": entry.url.absoluteString,
         "title": entry.title,
         "lastVisitTime": entry.lastVisitedAt.timeIntervalSince1970 * 1000,
         "visitCount": entry.visitCount, "typedCount": 0]
    }

    // MARK: - Downloads

    private func downloadJSON(_ item: DownloadItem, id: Int) -> [String: Any] {
        let state: String
        switch item.state {
        case .inProgress: state = "in_progress"
        case .finished: state = "complete"
        case .failed: state = "interrupted"
        case .cancelled: state = "interrupted"
        }
        return [
            "id": id, "url": item.url.absoluteString,
            "finalUrl": item.url.absoluteString, "filename": item.destination?.path ?? item.filename,
            "state": state, "exists": item.destination.map {
                FileManager.default.fileExists(atPath: $0.path)
            } ?? false,
            "startTime": ISO8601DateFormatter().string(from: item.startedAt), "mime": "",
        ]
    }

    // MARK: - Reading list

    private func answerReadingList(_ api: String, _ args: [Any]) throws -> Any? {
        switch api {
        case "readingList.query":
            let filter = args.first as? [String: Any] ?? [:]
            return readingList.entries.filter { entry in
                if let url = filter["url"] as? String, entry.url != url { return false }
                if let title = filter["title"] as? String,
                   !entry.title.localizedCaseInsensitiveContains(title) { return false }
                if let read = filter["hasBeenRead"] as? Bool,
                   entry.hasBeenRead != read { return false }
                return true
            }.map(readingListJSON)
        case "readingList.addEntry":
            let spec = args.first as? [String: Any] ?? [:]
            guard let url = spec["url"] as? String, !url.isEmpty else {
                throw Unsupported(what: "A reading-list entry needs an address")
            }
            readingList.add(
                url: url, title: spec["title"] as? String ?? "",
                hasBeenRead: spec["hasBeenRead"] as? Bool ?? false
            )
            return nil
        case "readingList.removeEntry":
            guard let url = args.first as? String else { return nil }
            readingList.remove(url: url)
            return nil
        case "readingList.updateEntry":
            let spec = args.first as? [String: Any] ?? [:]
            guard let url = spec["url"] as? String else { return nil }
            readingList.update(
                url: url, title: spec["title"] as? String,
                hasBeenRead: spec["hasBeenRead"] as? Bool
            )
            return nil
        default:
            return nil
        }
    }

    private func readingListJSON(_ entry: ReadingListEntry) -> [String: Any] {
        [
            "id": entry.id.uuidString,
            "url": entry.url,
            "title": entry.title,
            "creationTime": entry.created.timeIntervalSince1970 * 1000,
            "lastUpdateTime": entry.updated.timeIntervalSince1970 * 1000,
            "hasBeenRead": entry.hasBeenRead,
        ]
    }

    // MARK: - Side panel

    private func answerSidePanel(
        _ api: String, _ args: [Any], context: ExtensionShimContext
    ) throws -> Any? {
        switch api {
        case "sidePanel.setOptions":
            let options = args.first as? [String: Any] ?? [:]
            if let path = options["path"] as? String {
                defaults.set(path, forKey: panelKey("path", context.identifier))
            }
            if let enabled = options["enabled"] as? Bool {
                defaults.set(enabled, forKey: panelKey("enabled", context.identifier))
            }
            return nil
        case "sidePanel.getOptions":
            let path = defaults.string(forKey: panelKey("path", context.identifier)) ?? ""
            let enabled = defaults.object(forKey: panelKey("enabled", context.identifier))
                as? Bool ?? !path.isEmpty
            return ["enabled": enabled, "path": path]
        case "sidePanel.setPanelBehavior":
            if let on = (args.first as? [String: Any])?["openPanelOnActionClick"] as? Bool {
                defaults.set(on, forKey: panelKey("onClick", context.identifier))
            }
            return nil
        case "sidePanel.getPanelBehavior":
            return [
                "openPanelOnActionClick": defaults.bool(
                    forKey: panelKey("onClick", context.identifier)
                )
            ]
        case "sidePanel.open":
            let enabled = defaults.object(forKey: panelKey("enabled", context.identifier))
                as? Bool ?? true
            guard enabled,
                  let path = defaults.string(forKey: panelKey("path", context.identifier)),
                  let url = URL(string: path, relativeTo: URL(string: "chrome-extension://\(context.identifier)/"))
            else { throw Unsupported(what: "No active side panel for this extension") }
            if let onSidePanel {
                onSidePanel(context, url)
            } else {
                store.newTab(url: url, in: store.focusedWindow)
            }
            return nil
        case "sidePanel.close":
            return nil
        default:
            return nil
        }
    }

    private func panelKey(_ name: String, _ identifier: String) -> String {
        "chord.extensions.sidePanel.\(identifier).\(name)"
    }

    // MARK: - Tab groups (folders)

    private func answerTabGroups(
        _ api: String, _ args: [Any], context: ExtensionShimContext
    ) throws -> Any? {
        let window = store.window(inSpace: context.spaceID) ?? store.focusedWindow
        let groups = store.folders(in: window).sorted { $0.sortIndex < $1.sortIndex }
        switch api {
        case "tabGroups.query":
            let filter = args.first as? [String: Any] ?? [:]
            return groups.enumerated().compactMap { index, folder -> [String: Any]? in
                if let title = filter["title"] as? String, title != folder.name { return nil }
                if let collapsed = filter["collapsed"] as? Bool, collapsed != folder.isCollapsed {
                    return nil
                }
                return groupJSON(folder, number: index + 1)
            }
        case "tabGroups.get":
            guard let number = args.first as? Int, groups.indices.contains(number - 1)
            else { throw Unsupported(what: "No such group") }
            return groupJSON(groups[number - 1], number: number)
        case "tabGroups.update":
            guard let number = args.first as? Int, groups.indices.contains(number - 1)
            else { throw Unsupported(what: "No such group") }
            let changes = args.count > 1 ? args[1] as? [String: Any] ?? [:] : [:]
            if let title = changes["title"] as? String {
                store.renameFolder(groups[number - 1].id, to: title)
            }
            if let collapsed = changes["collapsed"] as? Bool,
               collapsed != groups[number - 1].isCollapsed {
                store.toggleFolderCollapsed(groups[number - 1].id)
            }
            let updated = store.folders(in: window).sorted { $0.sortIndex < $1.sortIndex }
            return updated.indices.contains(number - 1)
                ? groupJSON(updated[number - 1], number: number) : nil
        case "tabGroups.move":
            return nil
        default:
            return nil
        }
    }

    private func groupJSON(_ folder: Folder, number: Int) -> [String: Any] {
        ["id": number, "title": folder.name, "collapsed": folder.isCollapsed,
         "color": "grey", "windowId": 1, "shared": false]
    }

    private func answerTabGrouping(
        _ api: String, _ args: [Any], context: ExtensionShimContext
    ) throws -> Any? {
        let spec = args.first as? [String: Any] ?? [:]
        let ids = (spec["tabIds"] as? [Int]) ?? (spec["tabIds"] as? [NSNumber])?.map(\.intValue) ?? []
        let window = store.window(inSpace: context.spaceID) ?? store.focusedWindow
        let tabs = store.tabs.filter { $0.spaceID == context.spaceID }
            .sorted { $0.placement.order < $1.placement.order }
        let selected = ids.compactMap { tabs.indices.contains($0) ? tabs[$0] : nil }
        if api == "tabs.ungroup" {
            for tab in selected { store.moveTab(tab.id, toFolder: nil) }
            return nil
        }
        let groups = store.folders(in: window).sorted { $0.sortIndex < $1.sortIndex }
        let folderID: UUID
        if let number = spec["groupId"] as? Int, groups.indices.contains(number - 1) {
            folderID = groups[number - 1].id
        } else if let created = store.addFolder(
            name: (spec["createProperties"] as? [String: Any])?["title"] as? String ?? "Group"
        ) {
            folderID = created
        } else {
            throw Unsupported(what: "Could not create a group")
        }
        for tab in selected { store.moveTab(tab.id, toFolder: folderID) }
        let updated = store.folders(in: window).sorted { $0.sortIndex < $1.sortIndex }
        return updated.firstIndex(where: { $0.id == folderID }).map { $0 + 1 } ?? -1
    }

    // MARK: - Sessions, top sites, search

    private func recentlyClosed(context: ExtensionShimContext) async -> [[String: Any]] {
        guard let repository = store.archiveRepository else { return [] }
        let archived = (try? await repository.archivedTabs()) ?? []
        return archived.filter { $0.spaceID == context.spaceID }.prefix(25).map {
            ["tab": ["id": -1, "url": $0.url.absoluteString, "title": $0.displayTitle,
                     "windowId": 1, "index": 0]]
        }
    }

    private func topSites(context: ExtensionShimContext) async -> [[String: Any]] {
        let entries = (try? await store.historyRepository?.recentHistory(
            inSpace: context.spaceID, limit: 200
        )) ?? []
        var seen = Set<String>()
        return entries.compactMap { entry -> [String: Any]? in
            guard let host = entry.url.host(), seen.insert(host).inserted else { return nil }
            return ["title": entry.displayTitle, "url": entry.url.absoluteString]
        }.prefix(20).map { $0 }
    }

    private func answerSearch(_ args: [Any], context: ExtensionShimContext) -> Any? {
        let spec = args.first as? [String: Any] ?? [:]
        guard let text = spec["text"] as? String, !text.isEmpty else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&?=")
        let escaped = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        let url = URL(string: store.searchEngine.queryTemplate.replacingOccurrences(
            of: "%s", with: escaped
        ))
        if let url { store.newTab(url: url, in: store.focusedWindow) }
        return nil
    }

    struct Unsupported: LocalizedError {
        let what: String
        var errorDescription: String? { what }
    }
}
