import Foundation

/// One entry in the '@site' search registry (QoL #5). Pure data: a display
/// name, the aliases a leading '@' token is matched against (case-insensitive),
/// and a search URL template with a `%s` placeholder the typed query is
/// substituted into — the same shape as `SearchEngine`.
public struct SiteSearchEntry: Sendable, Hashable {
    public let name: String
    public let aliases: [String]
    public let urlTemplate: String

    public init(name: String, aliases: [String], urlTemplate: String) {
        self.name = name
        self.aliases = aliases
        self.urlTemplate = urlTemplate
    }
}

/// The curated, developer-oriented sites that a leading '@' token can dispatch
/// a search to. Entries are pure data and unit-tested; resolving an unknown
/// alias returns nil so the caller falls back to a normal search.
public enum SiteRegistry {
    public static let entries: [SiteSearchEntry] = [
        SiteSearchEntry(
            name: "GitHub", aliases: ["gh", "github"],
            urlTemplate: "https://github.com/search?q=%s"
        ),
        SiteSearchEntry(
            name: "Stack Overflow", aliases: ["so", "stackoverflow"],
            urlTemplate: "https://stackoverflow.com/search?q=%s"
        ),
        SiteSearchEntry(
            name: "npm", aliases: ["npm"],
            urlTemplate: "https://www.npmjs.com/search?q=%s"
        ),
        SiteSearchEntry(
            name: "Wikipedia", aliases: ["w", "wiki", "wikipedia"],
            urlTemplate: "https://en.wikipedia.org/w/index.php?search=%s"
        ),
        SiteSearchEntry(
            name: "YouTube", aliases: ["yt", "youtube"],
            urlTemplate: "https://www.youtube.com/results?search_query=%s"
        ),
    ]

    /// The first entry whose aliases contain `alias`, case-insensitively; nil
    /// when nothing is registered under that alias.
    public static func entry(forAlias alias: String) -> SiteSearchEntry? {
        let target = alias.lowercased()
        return entries.first { $0.aliases.contains(target) }
    }
}
