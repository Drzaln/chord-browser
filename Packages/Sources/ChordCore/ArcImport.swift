import Foundation

/// Why one item from Arc's sidebar was left out of a plan.
public enum ArcImportSkipReason: String, Sendable, Equatable, CaseIterable {
    case unsupportedScheme
    case invalidURL
    case missingURL
    /// The parser hit its object-graph ceiling before reading everything.
    case itemLimitReached

    public var label: String {
        switch self {
        case .unsupportedScheme: "unsupported URL scheme"
        case .invalidURL: "invalid URL"
        case .missingURL: "missing saved URL"
        case .itemLimitReached: "sidebar item limit reached"
        }
    }
}

/// One item the parser deliberately did not import. `detail` is the URL or the
/// Arc item id, capped so a corrupt file cannot inflate the plan.
public struct ArcImportSkip: Sendable, Equatable {
    public let space: String
    public let reason: ArcImportSkipReason
    public let detail: String

    public init(space: String, reason: ArcImportSkipReason, detail: String) {
        self.space = space
        self.reason = reason
        self.detail = String(detail.prefix(200))
    }
}

/// One page a plan will write, and the flat folder path it came from.
///
/// Chord's `Folder` is flat, so an Arc folder nested inside another becomes one
/// folder whose name is the path joined with " / " — see `ArcImportFolder`.
public struct ArcImportTab: Sendable, Equatable, Hashable {
    public let title: String
    public let url: URL
    /// Empty means the Space's top level (Chord's Pinned list, or the
    /// favourites grid for a favourite).
    public let folderPath: [String]

    public init(title: String, url: URL, folderPath: [String] = []) {
        self.title = title
        self.url = url
        self.folderPath = folderPath
    }

    public var folderName: String { folderPath.joined(separator: " / ") }
}

/// A folder found inside an Arc Space, identified by its full path.
public struct ArcImportFolder: Sendable, Equatable, Hashable {
    public let path: [String]

    public init(path: [String]) {
        self.path = path
    }

    /// The flat Chord folder name: "Parent / Child".
    public var displayName: String { path.joined(separator: " / ") }
    public var depth: Int { path.count }
}

/// One Arc Space and everything a plan will bring across for it.
public struct ArcImportSpace: Sendable, Equatable {
    public let name: String
    /// Arc's own emoji, if the Space had one. Chord stores an emoji in
    /// `Space.iconSymbol` and renders it as text.
    public let icon: String?
    /// Every folder, including empty ones, in Arc's order.
    public let folders: [ArcImportFolder]
    /// Arc's *Pinned* list, in order, with folder paths.
    public let pinned: [ArcImportTab]
    /// Arc's top-apps icons for this Space's profile, flattened.
    public let favourites: [ArcImportTab]

    public init(
        name: String,
        icon: String? = nil,
        folders: [ArcImportFolder] = [],
        pinned: [ArcImportTab] = [],
        favourites: [ArcImportTab] = []
    ) {
        self.name = name
        self.icon = icon
        self.folders = folders
        self.pinned = pinned
        self.favourites = favourites
    }

    public var topLevelPinCount: Int {
        pinned.reduce(0) { $0 + ($1.folderPath.isEmpty ? 1 : 0) }
    }

    public var folderedPinCount: Int { pinned.count - topLevelPinCount }

    public var itemCount: Int { pinned.count + favourites.count }

    /// Folders that lost their nesting because Chord's folders are flat.
    public var flattenedFolderCount: Int {
        folders.reduce(0) { $0 + ($1.depth > 1 ? 1 : 0) }
    }
}

/// A parsed Arc sidebar, ready for a dry run and then an apply pass.
///
/// `spaces` is everything that will be written. `skipped` records the pages and
/// items the parser refused (non-http schemes, broken URLs, the item ceiling).
/// Parsing never throws and never touches disk; the apply pass in `ChordStore`
/// is the only thing that writes.
public struct ArcImportPlan: Sendable, Equatable {
    public let spaces: [ArcImportSpace]
    public let skipped: [ArcImportSkip]
    /// A folder at or below `ArcSidebarParser.maximumFolderDepth` held more
    /// folders than the limit allows.
    public let depthLimitReached: Bool
    /// Arc URLs carrying `user:password@` were imported without the credentials.
    public let credentialsStripped: Int
    /// The object graph passed `ArcSidebarParser.maximumItemCount`.
    public let itemLimitReached: Bool

    public init(
        spaces: [ArcImportSpace],
        skipped: [ArcImportSkip] = [],
        depthLimitReached: Bool = false,
        credentialsStripped: Int = 0,
        itemLimitReached: Bool = false
    ) {
        self.spaces = spaces
        self.skipped = skipped
        self.depthLimitReached = depthLimitReached
        self.credentialsStripped = credentialsStripped
        self.itemLimitReached = itemLimitReached
    }

    public var spaceCount: Int { spaces.count }
    public var pinnedCount: Int { spaces.reduce(0) { $0 + $1.pinned.count } }
    public var favouriteCount: Int { spaces.reduce(0) { $0 + $1.favourites.count } }
    public var folderCount: Int { spaces.reduce(0) { $0 + $1.folders.count } }
    public var itemCount: Int { pinnedCount + favouriteCount }
    public var skippedCount: Int { skipped.count }

    /// Nested Arc folders that become one flat `Parent / Child` Chord folder.
    public var flattenedFolderCount: Int {
        spaces.reduce(0) { $0 + $1.flattenedFolderCount }
    }

    /// Arc folders that share a display name within one Space. Chord's folder
    /// match is by name, so these become a single folder on apply.
    public var mergedFolderCount: Int {
        spaces.reduce(0) { total, space in
            let names = space.folders.map(\.displayName)
            return total + (names.count - Set(names).count)
        }
    }

    public var isEmpty: Bool { spaces.isEmpty }

    public func skippedCount(for reason: ArcImportSkipReason) -> Int {
        skipped.reduce(0) { $1.reason == reason ? $0 + 1 : $0 }
    }
}

/// Reads Arc's `StorableSidebar.json`.
///
/// Arc's schema is undocumented and changes with the build, so this parser
/// treats every array and dictionary as optional: unknown keys are ignored,
/// missing containers yield an empty Space rather than an error, items are
/// de-duplicated by id, and folder recursion is capped at
/// `maximumFolderDepth` (64) with a visited set so a corrupt cyclic graph
/// terminates. It is pure and has no I/O.
public enum ArcSidebarParser {
    /// Folder nesting past this many levels is dropped and reported.
    public static let maximumFolderDepth = 64

    /// A hard ceiling on items visited, so a pathological file cannot make the
    /// parser (or the plan) unbounded. Real Arc sidebars are far smaller.
    public static let maximumItemCount = 5000

    /// All-or-nothing: `nil` means the bytes are not an Arc sidebar at all
    /// (corrupt JSON, JSON without `sidebar.containers`, or an unrelated file).
    /// Structural oddities inside a real sidebar are tolerated and reported in
    /// the plan instead.
    public static func parse(_ data: Data) -> ArcImportPlan? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let top = object as? [String: Any]
        else { return nil }

        let sidebar = (top["sidebar"] as? [String: Any]) ?? top
        let containers = containerObjects(sidebar["containers"])
        guard containers.contains(where: {
            $0["spaces"] is [Any] || $0["items"] is [Any]
        }) else { return nil }

        let items = itemMap(in: containers)
        var builder = Builder(items: items)

        // Top apps are shared by every Space of an Arc profile. Read them
        // before the Spaces so each Space gets its own profile's set.
        var favouritesByProfile: [String: [ArcImportTab]] = [:]
        for pair in favouriteContainers(in: containers, items: items) {
            var favourites: [ArcImportTab] = []
            var ignoredFolders: [ArcImportFolder] = []
            var taken = Set<String>()
            builder.collect(
                under: pair.id,
                space: "Favourites",
                path: [],
                depth: 0,
                tabs: &favourites,
                folders: &ignoredFolders,
                taken: &taken
            )
            guard !favourites.isEmpty else { continue }
            // Chord's favourites grid is flat, so a top-app folder's path is
            // discarded here rather than carried as invisible nesting.
            favouritesByProfile[pair.profile, default: []] += favourites.map {
                ArcImportTab(title: $0.title, url: $0.url)
            }
        }

        // When the whole file records favourites under one profile only, every
        // Space may use them: older Arc builds wrote a bare container id with
        // no profile marker, which lands under "Default". A file with several
        // profiles never lends one profile's favourites to another.
        let rawSpaces = rawSpaces(in: containers)
        let profiles = Set(rawSpaces.map { profileName($0.object["profile"]) })
        let favouriteProfiles = favouritesByProfile.filter { !$0.value.isEmpty }
        let loneFavourites = profiles.count == 1 && favouriteProfiles.count == 1
            ? favouriteProfiles.values.first
            : nil

        var spaces: [ArcImportSpace] = []
        for (index, raw) in rawSpaces.enumerated() {
            let name = cleaned(raw.object["title"] as? String) ?? "Arc Space \(index + 1)"
            let profile = profileName(raw.object["profile"])
            let emoji = spaceEmoji(raw.object)
            let pinnedContainer = containerID(
                "pinned", in: raw.object["newContainerIDs"]
            ) ?? containerID("pinned", in: raw.object["containerIDs"])

            var pinned: [ArcImportTab] = []
            var folders: [ArcImportFolder] = []
            if let pinnedContainer {
                var taken = Set<String>()
                builder.collect(
                    under: pinnedContainer,
                    space: name,
                    path: [],
                    depth: 0,
                    tabs: &pinned,
                    folders: &folders,
                    taken: &taken
                )
            }

            let favourites = favouriteProfiles[profile] ?? loneFavourites ?? []

            spaces.append(
                ArcImportSpace(
                    name: name,
                    icon: emoji,
                    folders: folders,
                    pinned: pinned,
                    favourites: favourites
                )
            )
        }

        return ArcImportPlan(
            spaces: spaces,
            skipped: builder.skipped,
            depthLimitReached: builder.depthLimitReached,
            credentialsStripped: builder.credentialsStripped,
            itemLimitReached: builder.itemLimitReached
        )
    }

    // MARK: - Container and item lookup

    /// `sidebar.containers` is an array in every build seen so far; a keyed
    /// object is accepted too, so a future build does not fail the import.
    private static func containerObjects(_ value: Any?) -> [[String: Any]] {
        if let array = value as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.compactMap { $0 as? [String: Any] }
        }
        return []
    }

    /// Arc writes an item list as `[id, object, id, object, …]`, though the
    /// object usually repeats its own id. Read both forms.
    private static func itemMap(in containers: [[String: Any]]) -> [String: [String: Any]] {
        var items: [String: [String: Any]] = [:]
        for container in containers {
            var pendingID: String?
            for entry in (container["items"] as? [Any]) ?? [] {
                if let id = entry as? String {
                    pendingID = id
                    continue
                }
                guard let item = entry as? [String: Any] else { continue }
                if let id = (item["id"] as? String) ?? pendingID {
                    items[id] = item
                }
                pendingID = nil
            }
        }
        return items
    }

    /// Space lists use the same alternating id/object shape.
    private static func rawSpaces(
        in containers: [[String: Any]]
    ) -> [(id: String?, object: [String: Any])] {
        var spaces: [(id: String?, object: [String: Any])] = []
        var seen = Set<String>()
        for container in containers {
            var pendingID: String?
            for entry in (container["spaces"] as? [Any]) ?? [] {
                if let id = entry as? String {
                    pendingID = id
                    continue
                }
                guard let space = entry as? [String: Any] else { continue }
                let id = (space["id"] as? String) ?? pendingID
                if let id {
                    guard seen.insert(id).inserted else { continue }
                }
                spaces.append((id, space))
                pendingID = nil
            }
        }
        return spaces
    }

    /// `topAppsContainerIDs` is a profile marker followed by a container id:
    /// `[{"default": {}}, "container", {"custom": …}, "container"]`. A bare
    /// string list is accepted as "Default" for older files.
    private static func favouriteContainers(
        in containers: [[String: Any]], items: [String: [String: Any]]
    ) -> [(profile: String, id: String)] {
        var pairs: [(profile: String, id: String)] = []
        for container in containers {
            let entries = (container["topAppsContainerIDs"] as? [Any]) ?? []
            var index = 0
            while index + 1 < entries.count {
                guard let marker = entries[index] as? [String: Any],
                      let id = entries[index + 1] as? String
                else {
                    index += 1
                    continue
                }
                pairs.append((profileName(marker), id))
                index += 2
            }
        }
        if !pairs.isEmpty { return pairs }

        // No profile markers at all: take every container id as Default's.
        var seen = Set<String>()
        for container in containers {
            for entry in (container["topAppsContainerIDs"] as? [Any]) ?? [] {
                guard let id = entry as? String, items[id] != nil,
                      seen.insert(id).inserted
                else { continue }
                pairs.append(("Default", id))
            }
        }
        return pairs
    }

    /// The id after `label` in a list of containers. Arc has written the label
    /// as a string and, lately, as an object keyed by it.
    private static func containerID(_ label: String, in value: Any?) -> String? {
        guard let list = value as? [Any] else { return nil }
        for index in list.indices where index + 1 < list.count {
            let entry = list[index]
            let matches = (entry as? String) == label
                || (entry as? [String: Any])?[label] != nil
            if matches, let id = list[index + 1] as? String { return id }
        }
        return nil
    }

    /// "Default", or the folder of the profile a Space or favourites belong to:
    /// `{"default": {}}` or `{"custom": {"_0": {"directoryBasename": …}}}`.
    private static func profileName(_ value: Any?) -> String {
        guard let custom = (value as? [String: Any])?["custom"] as? [String: Any]
        else { return "Default" }
        let inner = (custom["_0"] as? [String: Any]) ?? custom
        return cleaned(inner["directoryBasename"] as? String) ?? "Default"
    }

    private static func spaceEmoji(_ space: [String: Any]) -> String? {
        let iconType = (space["customInfo"] as? [String: Any])?["iconType"]
            as? [String: Any]
        let emoji = cleaned(iconType?["emoji_v2"] as? String)
            ?? cleaned(iconType?["emoji"] as? String)
        return emoji.map { String($0.prefix(16)) }
    }

    /// Whitespace-trimmed, non-empty, and capped so one absurd title cannot
    /// dominate a sidebar row.
    private static func cleaned(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return String(trimmed.prefix(300))
    }

    /// Walks one container's children, flattening folders into `folders` and
    /// pages into `tabs`. `taken` is per traversal so a cycle terminates and an
    /// item is visited once; `depth` is the folder depth of `id` itself.
    private struct Builder {
        let items: [String: [String: Any]]
        var skipped: [ArcImportSkip] = []
        var depthLimitReached = false
        var credentialsStripped = 0
        var itemLimitReached = false
        private var visited = 0

        /// Written out: with a `private` stored property the memberwise
        /// initializer is itself `private` to this type on the release
        /// runner's Swift (Xcode 26), though Xcode 27 lets it through.
        init(items: [String: [String: Any]]) {
            self.items = items
        }

        mutating func collect(
            under id: String,
            space: String,
            path: [String],
            depth: Int,
            tabs: inout [ArcImportTab],
            folders: inout [ArcImportFolder],
            taken: inout Set<String>
        ) {
            guard depth <= ArcSidebarParser.maximumFolderDepth,
                  let children = items[id]?["childrenIds"] as? [Any]
            else { return }

            for child in children {
                guard visited < ArcSidebarParser.maximumItemCount else {
                    itemLimitReached = true
                    return
                }
                guard let childID = child as? String,
                      let item = items[childID],
                      taken.insert(childID).inserted
                else { continue }
                visited += 1

                let data = item["data"] as? [String: Any]
                let tab = data?["tab"] as? [String: Any]
                let title = ArcSidebarParser.cleaned(
                    (item["title"] as? String) ?? (tab?["savedTitle"] as? String)
                )

                if tab != nil {
                    let rawURL = tab?["savedURL"] as? String
                    let resolved = resolve(rawURL, space: space, detail: rawURL ?? childID)
                    guard let url = resolved else { continue }
                    tabs.append(
                        ArcImportTab(
                            title: title ?? url.host() ?? url.absoluteString,
                            url: url,
                            folderPath: path
                        )
                    )
                    continue
                }

                // Anything with children that is not a tab is a folder. This is
                // deliberately loose: Arc's `data.list` marker comes and goes
                // between builds, but `childrenIds` is what makes it a group.
                guard item["childrenIds"] is [Any] else { continue }
                guard path.count + 1 <= ArcSidebarParser.maximumFolderDepth else {
                    depthLimitReached = true
                    continue
                }
                let folderName = title ?? "Folder"
                let childPath = path + [folderName]
                folders.append(ArcImportFolder(path: childPath))
                collect(
                    under: childID,
                    space: space,
                    path: childPath,
                    depth: depth + 1,
                    tabs: &tabs,
                    folders: &folders,
                    taken: &taken
                )
            }
        }

        /// A web page, with any credentials in the URL removed. Only `http` and
        /// `https` are pages Chord can browse; `arc://`, `chrome-extension://`,
        /// `file:` and the rest are reported, never imported.
        private mutating func resolve(
            _ text: String?, space: String, detail: String
        ) -> URL? {
            guard let text else {
                skipped.append(
                    ArcImportSkip(space: space, reason: .missingURL, detail: detail)
                )
                return nil
            }
            guard var parts = URLComponents(string: text) else {
                skipped.append(
                    ArcImportSkip(space: space, reason: .invalidURL, detail: detail)
                )
                return nil
            }
            guard let scheme = parts.scheme?.lowercased() else {
                skipped.append(
                    ArcImportSkip(space: space, reason: .invalidURL, detail: detail)
                )
                return nil
            }
            guard scheme == "http" || scheme == "https" else {
                skipped.append(
                    ArcImportSkip(
                        space: space, reason: .unsupportedScheme, detail: detail
                    )
                )
                return nil
            }
            if parts.user != nil || parts.password != nil {
                parts.user = nil
                parts.password = nil
                credentialsStripped += 1
            }
            guard let url = parts.url, let host = url.host(), !host.isEmpty else {
                skipped.append(
                    ArcImportSkip(space: space, reason: .invalidURL, detail: detail)
                )
                return nil
            }
            return url
        }
    }
}
