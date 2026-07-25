import Foundation

/// The search provider free-text queries are sent to from the address/command
/// bar (non-spec: user-requested). Built-in engines carry a query template with
/// a `%s` placeholder; `.custom` lets the user paste any template of the same
/// shape. Pure and `Codable` so it persists to `UserDefaults` and the command
/// bar ranking stays unit-testable.
public enum SearchEngine: Codable, Hashable, Sendable {
    case google
    case duckDuckGo
    case bing
    case brave
    /// A user-supplied template. `template` must contain the `%s` token, which
    /// the typed query (percent-encoded) is substituted into.
    case custom(name: String, template: String)

    /// The engines offered as ready-made choices in Settings, in menu order.
    public static let builtIns: [SearchEngine] = [.google, .duckDuckGo, .bing, .brave]

    public static let `default`: SearchEngine = .google

    public var displayName: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        case .brave: "Brave Search"
        case .custom(let name, _): name.isEmpty ? "Custom" : name
        }
    }

    /// The query template with a `%s` placeholder for the typed text.
    public var queryTemplate: String {
        switch self {
        case .google: "https://www.google.com/search?q=%s"
        case .duckDuckGo: "https://duckduckgo.com/?q=%s"
        case .bing: "https://www.bing.com/search?q=%s"
        case .brave: "https://search.brave.com/search?q=%s"
        case .custom(_, let template): template
        }
    }

    /// The provider's front page, used when the new-tab behaviour is "open the
    /// search engine". For a custom template it is best-effort — the scheme and
    /// host of the template, falling back to Google if that cannot be parsed.
    public var homepageURL: URL {
        switch self {
        case .google: return URL(string: "https://www.google.com")!
        case .duckDuckGo: return URL(string: "https://duckduckgo.com")!
        case .bing: return URL(string: "https://www.bing.com")!
        case .brave: return URL(string: "https://search.brave.com")!
        case .custom(_, let template):
            guard let components = URLComponents(string: template),
                  let host = components.host,
                  let url = URL(string: "\(components.scheme ?? "https")://\(host)")
            else { return URL(string: "https://www.google.com")! }
            return url
        }
    }

    /// Whether this value is one of the built-in engines (as opposed to a custom
    /// template), used by the Settings picker to decide selection.
    public var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }
}
