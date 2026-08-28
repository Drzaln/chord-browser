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

    /// "@gh swift" -> ("gh", "swift"); "@so stack overflow" -> ("so", "stack
    /// overflow"). nil when the text does not start with "@" (after trimming),
    /// or there is no alias, or there is no query — in which cases the caller
    /// falls through to a normal search, like a lone "?".
    public static func siteSearchQuery(_ raw: String) -> (alias: String, query: String)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("@") else { return nil }
        let rest = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }
        let parts = rest.split(separator: " ", maxSplits: 1)
        guard let alias = parts.first, !alias.isEmpty else { return nil }
        let query = (parts.count > 1 ? parts[1] : "").trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }
        return (String(alias), query)
    }

    /// TLDs we are willing to guess a host from (QoL #4). Anything else — a
    /// final label that is not one of these — is a search, so 'foo.grok' style
    /// gibberish cannot send the user to a DNS error. Conservative by design.
    private static let knownTLDs: Set<String> = [
        "com", "org", "net", "edu", "gov", "mil", "int",
        "io", "co", "ai", "dev", "app", "me", "tv", "info", "biz",
        "xyz", "site", "tech", "online", "store", "cloud", "blog", "pro",
        // Common country codes.
        "uk", "us", "de", "fr", "jp", "ca", "au", "nl", "se", "ch",
        "ru", "br", "in", "it", "es", "cn", "kr", "mx",
    ]

    /// A single token with a dot and no spaces is a host; anything else is a
    /// search. Deliberately conservative — guessing wrong sends the user to a
    /// DNS error instead of results.
    private static func looksLikeHost(_ text: String) -> Bool {
        guard !text.contains(" ") else { return false }
        let head = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        // Judge the domain on its own TLD, not the "www." prefix: this keeps
        // "www.example.com" a host while "www.grok" falls through to a search.
        let domain = head.hasPrefix("www.") ? String(head.dropFirst(4)) : head
        guard domain.contains(".") else { return text == "localhost" }
        guard let last = domain.split(separator: ".").last, !last.isEmpty else { return false }
        return knownTLDs.contains(String(last).lowercased())
    }
}
