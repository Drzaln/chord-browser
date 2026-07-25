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

    static func loadSearchEngine(
        _ defaults: UserDefaults = .standard
    ) -> SearchEngine {
        decode(SearchEngine.self, forKey: searchEngineKey, from: defaults) ?? .default
    }

    static func save(
        _ engine: SearchEngine, to defaults: UserDefaults = .standard
    ) {
        encode(engine, forKey: searchEngineKey, to: defaults)
    }

    static func loadNewTabBehavior(
        _ defaults: UserDefaults = .standard
    ) -> NewTabBehavior {
        decode(NewTabBehavior.self, forKey: newTabBehaviorKey, from: defaults) ?? .default
    }

    static func save(
        _ behavior: NewTabBehavior, to defaults: UserDefaults = .standard
    ) {
        encode(behavior, forKey: newTabBehaviorKey, to: defaults)
    }

    static func loadIdleWindow(
        _ defaults: UserDefaults = .standard
    ) -> IdleWindow {
        decode(IdleWindow.self, forKey: idleWindowKey, from: defaults) ?? .default
    }

    static func save(
        _ idleWindow: IdleWindow, to defaults: UserDefaults = .standard
    ) {
        encode(idleWindow, forKey: idleWindowKey, to: defaults)
    }

    // MARK: - JSON helpers

    private static func decode<T: Decodable>(
        _ type: T.Type, forKey key: String, from defaults: UserDefaults
    ) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func encode<T: Encodable>(
        _ value: T, forKey key: String, to defaults: UserDefaults
    ) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
