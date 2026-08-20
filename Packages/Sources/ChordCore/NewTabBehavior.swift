import Foundation

/// What a brand-new tab opens to (non-spec: user-requested). Resolving a
/// behaviour to a URL needs the configured `SearchEngine` for the `.searchEngine`
/// case, so the store owns the resolution — this stays a pure, `Codable`
/// preference value.
public enum NewTabBehavior: Codable, Hashable, Sendable {
    /// An empty page (`about:blank`) — no network, nothing to load.
    case blank
    /// The configured search engine's front page.
    case searchEngine
    /// A fixed URL the user chose.
    case custom(URL)

    public static let `default`: NewTabBehavior = .searchEngine

    public static let blankURL = URL(string: "about:blank")!

    /// The URL to load, given the engine in effect for the `.searchEngine` case.
    public func resolvedURL(searchEngine: SearchEngine) -> URL {
        switch self {
        case .blank: Self.blankURL
        case .searchEngine: searchEngine.homepageURL
        case .custom(let url): url
        }
    }
}
