import Foundation

/// The settings sheet's sections, in the order the segmented picker shows them.
///
/// The section list lives here rather than in `SettingsView` so the picker, the
/// catalog, and the search results cannot name different panes.
enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case general
    case sites
    case passwords
    case privacy
    case extensions
    case bookmarks
    case agents
    case updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .sites: "Sites"
        case .passwords: "Passwords"
        case .privacy: "Privacy & Data"
        case .extensions: "Extensions"
        case .bookmarks: "Bookmarks"
        case .agents: "Agents"
        case .updates: "Updates"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .sites: "globe"
        case .passwords: "key"
        case .privacy: "hand.raised"
        case .extensions: "puzzlepiece.extension"
        case .bookmarks: "bookmark"
        case .agents: "cpu"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }
}

/// One row a pane draws, named once.
///
/// The pane's `body` iterates `allCases` through `SettingsRows`, so this enum is
/// also the list of what is on screen. A row cannot be added to a pane without
/// adding a case here, and `SettingsCatalogTests` fails unless that case also
/// has title, blurb, and search words. `SettingsCatalogTests` pins the reverse
/// direction too: no catalog row without a pane case.
protocol SettingsRowType: CaseIterable, Hashable, Identifiable, RawRepresentable, Sendable
where RawValue == String {
    static var section: SettingsSection { get }
}

extension SettingsRowType {
    var id: String { rawValue }
    /// Where search sends someone who opens this row.
    var section: SettingsSection { Self.section }
    /// The catalog's display name. The pane heading reads this too, so a
    /// rename cannot make the row and its search result disagree.
    var title: String { SettingsCatalog.info(for: self)?.title ?? rawValue }
}

// MARK: - The rows, by pane

enum GeneralRow: String, CaseIterable, SettingsRowType {
    case defaultBrowser = "general.default-browser"
    case searchEngine = "general.search-engine"
    case newTab = "general.new-tab"
    case userAgent = "general.user-agent"
    case referrer = "general.referrer"
    case archiveInactiveTabs = "general.archive-inactive-tabs"
    case gestures = "general.gestures"
    case backgroundTabs = "general.background-tabs"
    case developerMode = "general.developer-mode"

    static let section = SettingsSection.general
}

enum SitesRow: String, CaseIterable, SettingsRowType {
    case routingRules = "sites.routing-rules"
    case siteOverrides = "sites.site-overrides"

    static let section = SettingsSection.sites
}

enum PasswordsRow: String, CaseIterable, SettingsRowType {
    case vaultLock = "passwords.vault-lock"
    case savedPasswords = "passwords.saved-passwords"
    case neverSaved = "passwords.never-saved"

    static let section = SettingsSection.passwords
}

enum PrivacyRow: String, CaseIterable, SettingsRowType {
    case clearBrowsingData = "privacy.clear-browsing-data"
    case sitePermissions = "privacy.site-permissions"
    case cookiesForSite = "privacy.cookies-for-a-site"

    static let section = SettingsSection.privacy
}

enum ExtensionsRow: String, CaseIterable, SettingsRowType {
    case extensions = "extensions.list"

    static let section = SettingsSection.extensions
}

enum BookmarksRow: String, CaseIterable, SettingsRowType {
    case bookmarks = "bookmarks.list"

    static let section = SettingsSection.bookmarks
}

enum AgentsRow: String, CaseIterable, SettingsRowType {
    case localAgents = "agents.local-agents"
    case sharedSpaces = "agents.shared-spaces"
    case javascript = "agents.javascript"
    case connect = "agents.connect"

    static let section = SettingsSection.agents
}

enum UpdatesRow: String, CaseIterable, SettingsRowType {
    case updates = "updates.check"

    static let section = SettingsSection.updates
}

// MARK: - Catalog entries

/// One visible settings row: what it is called, what it does, and the words
/// someone might type looking for it.
struct SettingsRowInfo: Identifiable, Hashable, Sendable {
    let id: String
    let section: SettingsSection
    let title: String
    let blurb: String
    /// Lower-case synonyms, product names, and menu paths. Search folds case
    /// and diacritics on both sides, so the stored spelling only matters for
    /// readability.
    let keywords: [String]
    /// The key that reaches this setting's control, when one exists.
    let shortcut: String?
}

extension SettingsRowInfo {
    init<Row: SettingsRowType>(
        _ row: Row,
        title: String,
        blurb: String,
        keywords: [String],
        shortcut: String? = nil
    ) {
        self.init(
            id: row.rawValue,
            section: Row.section,
            title: title,
            blurb: blurb,
            keywords: keywords,
            shortcut: shortcut
        )
    }
}

/// A truthful answer for a lookalike that is not a settings row.
///
/// Some words people type in a settings search belong to a menu command or to
/// behaviour that is always on: "dark", "zoom", "adblock". A note appears in
/// search only — it is not drawn in a pane — and says where the control really
/// is. This is how the catalog can answer those queries without inventing a
/// setting that does not exist.
struct SettingsNote: Identifiable, Hashable, Sendable {
    let id: String
    let section: SettingsSection
    let title: String
    let blurb: String
    let keywords: [String]
    let shortcut: String?
}

/// One ranked search result: a row or a note.
struct SettingsSearchHit: Identifiable, Hashable, Sendable {
    let id: String
    let section: SettingsSection
    let title: String
    let blurb: String
    let shortcut: String?
    /// Notes are find-only; opening one goes to the section but marks no row.
    let isNote: Bool
    /// The keyword that matched, when the title and blurb did not.
    let matchedKeyword: String?
    /// Lower is better. Exposed so the ordering is testable.
    let score: Int
}

struct SettingsMatch: Equatable, Sendable {
    let score: Int
    let keyword: String?
}

// MARK: - The catalog

/// Every settings row, written down once.
///
/// The panes draw their rows from the enums above through `SettingsRows`; this
/// is the same list with the words search needs. A row is visible *because* it
/// is in a pane enum, and it is searchable *because* this table has an entry
/// for it — the tests hold the two halves together.
enum SettingsCatalog {

    // MARK: rows

    static let rows: [SettingsRowInfo] =
        generalRows + sitesRows + passwordsRows + privacyRows + extensionsRows
            + bookmarksRows + agentsRows + updatesRows

    static func rows(in section: SettingsSection) -> [SettingsRowInfo] {
        rows.filter { $0.section == section }
    }

    static func info<Row: SettingsRowType>(for row: Row) -> SettingsRowInfo? {
        rows.first { $0.id == row.rawValue }
    }

    static let generalRows: [SettingsRowInfo] = [
        .init(
            GeneralRow.defaultBrowser,
            title: "Default Browser",
            blurb: "Make Chord the browser that links from other apps open in.",
            keywords: [
                "default", "default browser", "browser", "links", "open links",
                "other apps", "system", "http", "make default",
            ]
        ),
        .init(
            GeneralRow.searchEngine,
            title: "Search Engine",
            blurb: "Where the address bar and command bar send what you type.",
            keywords: [
                "search", "engine", "search engine", "google", "duckduckgo", "bing",
                "custom search", "address bar", "command bar", "default search", "provider",
            ]
        ),
        .init(
            GeneralRow.newTab,
            title: "New Tab Opens",
            blurb: "A blank page, your search engine, or a page you choose.",
            keywords: [
                "new tab", "tab", "home", "homepage", "start page", "blank page",
                "new tab page", "specific page", "custom url",
            ]
        ),
        .init(
            GeneralRow.userAgent,
            title: "User Agent",
            blurb: "How Chord identifies itself to sites, plus per-site exceptions.",
            keywords: [
                "user agent", "ua", "agent", "identity", "identify", "spoof", "chrome",
                "firefox", "safari", "mobile", "site rules", "per-site", "per site",
                "override", "domain", "compatibility",
            ]
        ),
        .init(
            GeneralRow.referrer,
            title: "Referrer",
            blurb: "What address a site is told you came from, plus per-site exceptions.",
            keywords: [
                "referrer", "referer", "refer", "strip", "tracking", "site rules",
                "per-site", "per site", "override", "domain",
            ]
        ),
        .init(
            GeneralRow.archiveInactiveTabs,
            title: "Archive Inactive Tabs",
            blurb: "Move tabs you have not touched for a while to the archive.",
            keywords: [
                "archive", "inactive", "idle", "auto archive", "old tabs", "sweep",
                "timeout", "memory", "close", "hibernate", "hibernation",
            ]
        ),
        .init(
            GeneralRow.gestures,
            title: "Gestures",
            blurb: "Swipe right on a page with no back history to close the tab.",
            keywords: [
                "gesture", "gestures", "swipe", "trackpad", "mouse", "back",
                "close tab", "navigation",
            ]
        ),
        .init(
            GeneralRow.backgroundTabs,
            title: "Background Tabs",
            blurb: "Suspend tabs you can't see to save power, at the cost of pages that work in the background.",
            keywords: [
                "background", "background tabs", "suspend", "sleep", "battery", "power",
                "energy", "cpu", "hidden", "throttle", "performance", "memory",
            ]
        ),
        .init(
            GeneralRow.developerMode,
            title: "Developer Mode",
            blurb: "Show the Web Inspector and DRM Diagnostics.",
            keywords: [
                "developer", "dev", "web inspector", "inspector", "drm", "diagnostics",
                "debug", "console", "webkit",
            ]
        ),
    ]

    static let sitesRows: [SettingsRowInfo] = [
        .init(
            SitesRow.routingRules,
            title: "Routing Rules",
            blurb: "Send a site's links to the Space they belong in.",
            keywords: [
                "routing", "routing rules", "route", "rules", "space", "spaces", "link",
                "links", "open in", "redirect", "domain", "subdomain", "host",
            ]
        ),
        .init(
            SitesRow.siteOverrides,
            title: "Site Overrides",
            blurb: "Your own CSS, JavaScript, and hidden elements for a site.",
            keywords: [
                "site override", "site overrides", "override", "overrides", "css", "style",
                "javascript", "js", "hide", "hidden", "element", "selector", "appearance",
                "theme", "custom css", "userscript",
            ]
        ),
    ]

    static let passwordsRows: [SettingsRowInfo] = [
        .init(
            PasswordsRow.vaultLock,
            title: "Vault Lock",
            blurb: "When the saved-password vault locks; filling then asks for Touch ID.",
            keywords: [
                "vault", "lock", "touch id", "biometric", "timeout", "security",
                "keychain", "screen lock", "idle",
            ]
        ),
        .init(
            PasswordsRow.savedPasswords,
            title: "Saved Passwords",
            blurb: "Every password Chord has saved, with reveal and delete.",
            keywords: [
                "password", "passwords", "saved", "credential", "credentials", "login",
                "sign in", "autofill", "reveal", "delete", "keychain",
            ]
        ),
        .init(
            PasswordsRow.neverSaved,
            title: "Never Saved",
            blurb: "Sites where Chord never offers to save a password.",
            keywords: [
                "never save", "never saved", "ask again", "password", "passwords", "site",
                "ignore", "dismiss", "silence",
            ]
        ),
    ]

    static let privacyRows: [SettingsRowInfo] = [
        .init(
            PrivacyRow.clearBrowsingData,
            title: "Clear Browsing Data",
            blurb: "Clear cache, cookies, site storage, and history across every Space.",
            keywords: [
                "clear", "clear browsing data", "cache", "cached", "cookies", "history",
                "storage", "local storage", "session storage", "indexeddb", "service worker",
                "browsing data", "delete", "privacy", "clean",
            ]
        ),
        .init(
            PrivacyRow.sitePermissions,
            title: "Site Permissions",
            blurb: "Camera, microphone, location, and notification choices, per Space.",
            keywords: [
                "permissions", "camera", "microphone", "mic", "location", "geolocation",
                "notifications", "notification", "allow", "block", "blocked", "revoke",
                "site", "privacy", "audio", "video",
            ]
        ),
        .init(
            PrivacyRow.cookiesForSite,
            title: "Cookies for a Site",
            blurb: "Inspect and clear the cookies one site holds in the current Space.",
            keywords: [
                "cookie", "cookies", "site", "inspect", "clear", "sign out", "privacy",
                "session", "storage",
            ]
        ),
    ]

    static let extensionsRows: [SettingsRowInfo] = [
        .init(
            ExtensionsRow.extensions,
            title: "Extensions",
            blurb: "Install from the Chrome Web Store or a .crx/.xpi, then enable, disable, or uninstall.",
            keywords: [
                "extension", "extensions", "addon", "add-on", "crx", "xpi",
                "chrome web store", "web store", "install", "uninstall", "enable",
                "disable", "permissions", "plugin", "signed", "unsigned", "developer mode",
                "pin", "pinned", "toolbar", "private window", "side panel",
            ]
        ),
    ]

    static let bookmarksRows: [SettingsRowInfo] = [
        .init(
            BookmarksRow.bookmarks,
            title: "Bookmarks",
            blurb: "The bookmarks extensions and the command bar read; open or remove one.",
            keywords: [
                "bookmark", "bookmarks", "favorites", "favourites", "saved pages",
                "remove bookmark", "delete bookmark", "star",
            ]
        ),
    ]

    static let agentsRows: [SettingsRowInfo] = [
        .init(
            AgentsRow.localAgents,
            title: "Local Agents (MCP)",
            blurb: "Let AI agents on this Mac connect to Chord over a private socket.",
            keywords: [
                "agent", "agents", "mcp", "model context protocol", "ai", "claude",
                "automation", "socket", "allow agents", "local agents",
            ]
        ),
        .init(
            AgentsRow.sharedSpaces,
            title: "Shared Spaces",
            blurb: "Which Spaces an agent may read, and which it may also act in.",
            keywords: [
                "agent", "agents", "space", "spaces", "shared", "share", "read",
                "read & act", "act", "access", "permission",
            ]
        ),
        .init(
            AgentsRow.javascript,
            title: "JavaScript",
            blurb: "Whether agents may run their own JavaScript in a page, asked every time.",
            keywords: [
                "agent", "agents", "javascript", "js", "eval", "eval_js", "script",
                "run javascript",
            ]
        ),
        .init(
            AgentsRow.connect,
            title: "Connect an Agent",
            blurb: "The command and config that point Claude Code or another agent at Chord.",
            keywords: [
                "agent", "agents", "connect", "claude code", "config", "command",
                "mcp-stdio", "setup", "helper",
            ]
        ),
    ]

    static let updatesRows: [SettingsRowInfo] = [
        .init(
            UpdatesRow.updates,
            title: "Updates",
            blurb: "Check GitHub for a new version, then download, install, and restart.",
            keywords: [
                "update", "updates", "version", "upgrade", "release", "github",
                "check for updates", "download", "install", "restart", "self update",
            ]
        ),
    ]

    // MARK: notes

    /// Lookalikes that are not settings. Search-only; never drawn in a pane.
    static let notes: [SettingsNote] = [
        SettingsNote(
            id: "note.appearance",
            section: .general,
            title: "Appearance",
            blurb: "Chord follows your Mac's light or dark appearance. Change it in System Settings › Appearance.",
            keywords: [
                "appearance", "dark", "dark mode", "light", "light mode", "theme",
                "system appearance", "colours", "colors",
            ],
            shortcut: nil
        ),
        SettingsNote(
            id: "note.page-zoom",
            section: .general,
            title: "Page Zoom",
            blurb: "Zoom a page with ⌘= and ⌘-, and return to actual size with ⌘0. These are menu commands, not a setting.",
            keywords: [
                "zoom", "zoom in", "zoom out", "actual size", "page zoom", "magnify",
                "text size", "scale", "⌘=", "⌘-", "⌘0", "cmd =", "cmd -", "cmd 0",
            ],
            shortcut: "⌘= / ⌘- / ⌘0"
        ),
        SettingsNote(
            id: "note.private-windows",
            section: .general,
            title: "Private Windows",
            blurb: "⌘⇧N opens a private window. Its cookies, history, and tabs are not kept when it closes.",
            keywords: [
                "private", "private window", "private windows", "incognito",
                "private browsing", "privacy", "⌘⇧n", "cmd shift n",
            ],
            shortcut: "⇧⌘N"
        ),
        SettingsNote(
            id: "note.downloads",
            section: .general,
            title: "Downloads",
            blurb: "Downloads open from the toolbar and go to your Mac's Downloads folder. Chord has no folder setting.",
            keywords: [
                "download", "downloads", "file", "files", "save", "folder", "download folder",
            ],
            shortcut: nil
        ),
        SettingsNote(
            id: "note.import",
            section: .general,
            title: "Import from Another Browser",
            blurb: "Use the File menu: Import Bookmarks… (an HTML export), Import from Arc…, and Import Passwords… (Chrome, Brave, Edge and other Chromium browsers).",
            keywords: [
                "import", "migrate", "bring over", "arc", "chrome", "brave", "edge",
                "chromium", "bookmarks html", "export", "switch browser",
            ],
            shortcut: nil
        ),
        SettingsNote(
            id: "note.content-blocking",
            section: .privacy,
            title: "Content Blocking",
            blurb: "Content blocking is on by default (EasyList and EasyPrivacy) and has no in-app off switch.",
            keywords: [
                "blocking", "content blocking", "adblock", "ad block", "ads",
                "advertisements", "tracker", "trackers", "easylist", "easyprivacy",
                "shield", "privacy",
            ],
            shortcut: nil
        ),
    ]

    // MARK: searching

    /// Case- and diacritic-insensitive form used on both sides of every match.
    /// Width folding is included so a full-width character typed by a Japanese
    /// or Chinese input method still finds the ASCII word.
    static func normalized(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    /// How well one entry matches `query`.
    ///
    /// Lower is better: title prefix, title contains, keyword prefix, keyword
    /// contains, blurb, section name. `keyword` is the first keyword that lost
    /// the match, so the result view can show why the row is here.
    static func match(
        _ query: String,
        title: String,
        keywords: [String],
        blurb: String,
        section: String
    ) -> SettingsMatch? {
        let needle = normalized(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }

        let foldedTitle = normalized(title)
        let foldedKeywords = keywords.map(normalized)
        let foldedBlurb = normalized(blurb)
        let foldedSection = normalized(section)

        if foldedTitle.hasPrefix(needle) {
            return SettingsMatch(score: 0, keyword: nil)
        }
        if foldedTitle.contains(needle) {
            return SettingsMatch(score: 1, keyword: nil)
        }
        if let keyword = zip(keywords, foldedKeywords)
            .first(where: { $0.1.hasPrefix(needle) })?.0 {
            return SettingsMatch(score: 2, keyword: keyword)
        }
        if let keyword = zip(keywords, foldedKeywords)
            .first(where: { $0.1.contains(needle) })?.0 {
            return SettingsMatch(score: 3, keyword: keyword)
        }
        if foldedBlurb.contains(needle) {
            return SettingsMatch(score: 4, keyword: nil)
        }
        if foldedSection.contains(needle) {
            return SettingsMatch(score: 5, keyword: nil)
        }
        return nil
    }

    /// Rows and notes whose words match `typed`, best first.
    ///
    /// Every word must appear somewhere in the entry, so "chrome store" finds
    /// the Chrome Web Store field even though no single phrase says that. A
    /// multi-word query that only matches across fields ranks last.
    static func search(_ typed: String) -> [SettingsSearchHit] {
        let needle = normalized(typed).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let words = needle.split(whereSeparator: \.isWhitespace).map(String.init)

        var found: [(hit: SettingsSearchHit, order: Int)] = []
        var order = 0

        func consider(
            id: String,
            section: SettingsSection,
            title: String,
            blurb: String,
            keywords: [String],
            shortcut: String?,
            isNote: Bool
        ) {
            order += 1
            if let match = match(
                needle, title: title, keywords: keywords, blurb: blurb,
                section: section.title
            ) {
                found.append((
                    SettingsSearchHit(
                        id: id, section: section, title: title, blurb: blurb,
                        shortcut: shortcut, isNote: isNote,
                        matchedKeyword: match.keyword, score: match.score
                    ),
                    order
                ))
                return
            }

            // Words split across fields: "chrome store", "site camera".
            let haystack = normalized(
                ([title, blurb, section.title, shortcut ?? ""] + keywords)
                    .joined(separator: " ")
            )
            guard words.allSatisfy({ haystack.contains($0) }) else { return }
            let keyword = zip(keywords, keywords.map(normalized))
                .first(where: { $0.1.contains(words[0]) })?.0
            found.append((
                SettingsSearchHit(
                    id: id, section: section, title: title, blurb: blurb,
                    shortcut: shortcut, isNote: isNote,
                    matchedKeyword: keyword, score: 6
                ),
                order
            ))
        }

        for row in rows {
            consider(
                id: row.id, section: row.section, title: row.title, blurb: row.blurb,
                keywords: row.keywords, shortcut: row.shortcut, isNote: false
            )
        }
        for note in notes {
            consider(
                id: note.id, section: note.section, title: note.title, blurb: note.blurb,
                keywords: note.keywords, shortcut: note.shortcut, isNote: true
            )
        }

        return found
            .sorted {
                $0.hit.score == $1.hit.score
                    ? $0.order < $1.order
                    : $0.hit.score < $1.hit.score
            }
            .map(\.hit)
    }
}
