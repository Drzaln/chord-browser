import Foundation

/// Turns whatever the user typed into something navigable.
///
/// Pure and dependency-free so it is unit-testable, and so the command bar (M3)
/// can reuse it unchanged.
public enum URLInput {
    /// The template used when a caller does not pass one. `%s` is where the
    /// percent-encoded query goes. Configurable per user via `SearchEngine`;
    /// this default keeps the pure API usable without a settings dependency.
    public static let defaultSearchTemplate = SearchEngine.default.queryTemplate

    public static func resolve(
        _ raw: String, searchTemplate: String = defaultSearchTemplate
    ) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = URL(string: text), let scheme = url.scheme, !scheme.isEmpty {
            return url
        }

        if looksLikeHost(text), let url = URL(string: "https://\(text)") {
            return url
        }

        return search(for: text, template: searchTemplate)
    }

    /// Whether `raw` will be treated as a search query rather than a direct
    /// navigation. Mirrors the branch `resolve` takes, so the command bar can
    /// label a row without re-parsing the resulting URL — which was impossible
    /// once the search template stopped being a fixed prefix.
    public static func isSearch(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if let url = URL(string: text), let scheme = url.scheme, !scheme.isEmpty {
            return false
        }
        return !looksLikeHost(text)
    }

    public static func search(
        for query: String, template: String = defaultSearchTemplate
    ) -> URL? {
        let encoded = query.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? query
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    /// "?golang.org" or "? golang.org" -> "golang.org"; nil when the text does
    /// not begin with "?" (after trimming) or is nothing but the "?".
    public static func forcedSearchQuery(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("?") else { return nil }
        let rest = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    /// A single token with a dot and no spaces is a host; anything else is a
    /// search. Deliberately conservative — guessing wrong sends the user to a
    /// DNS error instead of results.
    private static func looksLikeHost(_ text: String) -> Bool {
        guard !text.contains(" ") else { return false }
        let head = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        guard head.contains(".") else { return text == "localhost" }
        guard let last = head.split(separator: ".").last, last.count >= 2 else { return false }
        return last.allSatisfy(\.isLetter)
    }
}
