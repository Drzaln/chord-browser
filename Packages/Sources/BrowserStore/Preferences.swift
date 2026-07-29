import BrowserCore
import Foundation

/// Small `UserDefaults`-backed codec for the user-facing browser preferences
/// (non-spec: user-requested) — the search engine and the new-tab behaviour.
/// These are choices, not schema-bound user data, so they live in `UserDefaults`
/// as JSON alongside the sidebar-width / collapsed flags, not in SQLite.
enum Preferences {
    private static let searchEngineKey = "prefs.searchEngine"
    private static let newTabBehaviorKey = "prefs.newTabBehavior"
    private static let idleWindowKey = "prefs.idleWindow"
    private static let userAgentKey = "prefs.userAgent"
    private static let collapsedPinnedSpacesKey = "prefs.collapsedPinnedSpaces"
    // Unprefixed, unlike the rest: these two predate this file and were written
    // straight from `TabStore`. Kept verbatim so an existing profile does not
    // silently reset its sidebar when the state moved to `WindowState`.
    private static let sidebarCollapsedKey = "sidebar.collapsed"
    private static let sidebarWidthKey = "sidebar.width"

    static func loadSearchEngine(
        _ defaults: any PreferenceStore = UserDefaults.standard
    ) -> SearchEngine {
        decode(SearchEngine.self, forKey: searchEngineKey, from: defaults) ?? .default
    }

    static func save(
        _ engine: SearchEngine, to defaults: any PreferenceStore = UserDefaults.standard
    ) {
        encode(engine, forKey: searchEngineKey, to: defaults)
    }

    static func loadNewTabBehavior(
        _ defaults: any PreferenceStore = UserDefaults.standard
    ) -> NewTabBehavior {
        decode(NewTabBehavior.self, forKey: newTabBehaviorKey, from: defaults) ?? .default
    }

    static func save(
        _ behavior: NewTabBehavior, to defaults: any PreferenceStore = UserDefaults.standard
    ) {
        encode(behavior, forKey: newTabBehaviorKey, to: defaults)
    }

    static func loadIdleWindow(
        _ defaults: any PreferenceStore = UserDefaults.standard
    ) -> IdleWindow {
        decode(IdleWindow.self, forKey: idleWindowKey, from: defaults) ?? .default
    }

    static func save(
        _ idleWindow: IdleWindow, to defaults: any PreferenceStore = UserDefaults.standard
    ) {
        encode(idleWindow, forKey: idleWindowKey, to: defaults)
    }

    static func loadUserAgent(
        _ defaults: any PreferenceStore = UserDefaults.standard
    ) -> UserAgentPreference {
        decode(UserAgentPreference.self, forKey: userAgentKey, from: defaults) ?? .default
    }

    static func save(
        _ userAgent: UserAgentPreference, to defaults: any PreferenceStore = UserDefaults.standard
    ) {
        encode(userAgent, forKey: userAgentKey, to: defaults)
    }

    /// The Spaces whose Pinned-tabs section is collapsed (non-spec:
    /// user-requested). A window preference, so it lives here as JSON rather
    /// than in the schema.
    static func loadCollapsedPinnedSpaces(
        _ defaults: any PreferenceStore = UserDefaults.standard
    ) -> Set<UUID> {
        let strings = decode([String].self, forKey: collapsedPinnedSpacesKey, from: defaults) ?? []
        return Set(strings.compactMap(UUID.init(uuidString:)))
    }

    static func save(
        collapsedPinnedSpaces spaces: Set<UUID>, to defaults: any PreferenceStore = UserDefaults.standard
    ) {
        encode(spaces.map(\.uuidString), forKey: collapsedPinnedSpacesKey, to: defaults)
    }

    // MARK: - Sidebar (per-window; see `WindowState`)

    /// Stored as a plain `Bool`/`Double` rather than JSON — these two keys
    /// already existed in that shape, and rewriting them would reset the sidebar
    /// of every existing profile.
    static func loadSidebarCollapsed(
        _ defaults: any PreferenceStore = UserDefaults.standard
    ) -> Bool {
        defaults.object(forKey: sidebarCollapsedKey) as? Bool ?? false
    }

    static func save(
        isSidebarCollapsed collapsed: Bool, to defaults: any PreferenceStore = UserDefaults.standard
    ) {
        defaults.set(collapsed, forKey: sidebarCollapsedKey)
    }

    /// Defaults to 240 when unset, rather than to zero, which is not a usable
    /// width.
    static func loadSidebarWidth(
        _ defaults: any PreferenceStore = UserDefaults.standard
    ) -> CGFloat {
        let saved = defaults.object(forKey: sidebarWidthKey) as? Double ?? 0
        return saved > 0 ? CGFloat(saved) : 240
    }

    static func save(
        sidebarWidth width: CGFloat, to defaults: any PreferenceStore = UserDefaults.standard
    ) {
        defaults.set(Double(width), forKey: sidebarWidthKey)
    }

    // MARK: - JSON helpers

    private static func decode<T: Decodable>(
        _ type: T.Type, forKey key: String, from defaults: any PreferenceStore
    ) -> T? {
        guard let data = defaults.object(forKey: key) as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func encode<T: Encodable>(
        _ value: T, forKey key: String, to defaults: any PreferenceStore
    ) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
